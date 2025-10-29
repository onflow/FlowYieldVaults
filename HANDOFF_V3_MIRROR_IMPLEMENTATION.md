# PunchSwap V3 Mirror Test Implementation - Handoff Prompt

## Context & Background

This repository contains the Tidal yield farming platform built on Flow blockchain. We've successfully integrated PunchSwap V3 (Uniswap V3-compatible) pools and now need to create actual mirror tests that use real v3 pools for numerical validation against Python simulations.

### What's Already Done ✅

1. **Infrastructure Setup**: PunchSwap V3 contracts deployed, tokens bridged, pools operational
2. **Documentation**: Comprehensive strategy docs in `docs/v3-pool-integration-strategy.md` and `docs/v3-mirror-test-setup.md`
3. **Helper Functions**: `cadence/tests/test_helpers_v3.cdc` with v3 integration utilities
4. **Existing Tests**: MockV3-based mirror tests in `cadence/tests/*_mirror_test.cdc` (keep these for unit testing)

### Repository Structure
```
/Users/keshavgupta/tidal-sc/
├── cadence/
│   ├── contracts/mocks/MockV3.cdc          # Simple capacity mock (keep)
│   └── tests/
│       ├── test_helpers.cdc                # General test helpers
│       ├── test_helpers_v3.cdc             # V3 integration helpers (NEW)
│       ├── rebalance_liquidity_mirror_test.cdc  # MockV3 version
│       └── [NEW] rebalance_liquidity_v3_mirror_test.cdc
├── lib/
│   ├── TidalProtocol/                      # Main protocol
│   │   └── DeFiActions/
│   │       └── cadence/contracts/connectors/evm/
│   │           └── UniswapV3SwapConnectors.cdc  # V3 swap interface
│   └── tidal-protocol-research/            # Python simulations
│       └── tidal_protocol_sim/results/     # Simulation outputs
├── local/
│   ├── punchswap/
│   │   ├── setup_punchswap.sh              # Deploy v3 contracts
│   │   ├── e2e_punchswap.sh                # Deploy tokens, create pools
│   │   └── punchswap.env                   # Contract addresses
│   └── setup_bridged_tokens.sh             # Bridge Cadence ↔ EVM
└── docs/
    ├── v3-pool-integration-strategy.md     # Strategy overview
    ├── v3-mirror-test-setup.md             # Setup walkthrough
    └── mirroring-overview.md               # Mirror test overview
```

### PunchSwap V3 Addresses (Local Deployment)
```
V3_FACTORY=0x986Cb42b0557159431d48fE0A40073296414d410
SWAP_ROUTER=0x717C515542929d3845801aF9a851e72fE27399e2
QUOTER=0x14885A6C9d1a9bDb22a9327e1aA7730e60F79399
POSITION_MANAGER=0x9cD8d8622753C4FEBef4193e4ccaB6ae4C26772a
```

### Simulation Baseline (from `lib/tidal-protocol-research/tidal_protocol_sim/results/Rebalance_Liquidity_Test`)
```json
{
  "pool_size_usd": 250000,
  "concentration": 0.95,
  "price_deviation_threshold": 0.05,
  "max_safe_single_swap": 350000,
  "cumulative_capacity": 358000,
  "breaking_point": 358000
}
```

## Task: Create Real V3 Mirror Test

### Objective
Create `cadence/tests/rebalance_liquidity_v3_mirror_test.cdc` that:
1. Uses real PunchSwap V3 pools (MOET/USDC or YIELD/MOET)
2. Executes actual swaps via UniswapV3SwapConnectors
3. Measures real price impact and slippage
4. Compares cumulative capacity with simulation baseline
5. Logs numerical results for comparison: `MIRROR:price_before`, `MIRROR:price_after`, `MIRROR:slippage`, `MIRROR:cumulative_volume`

### Key Requirements

#### 1. Test Setup Must Include:
- Deploy all required contracts (including EVM bridge contracts)
- Setup COA for protocol account (for EVM interaction)
- Bridge MOET to EVM
- Get MOET EVM address for v3 swapper
- Create or use existing MOET/USDC pool on PunchSwap v3
- Initialize prices via MockOracle

#### 2. Test Flow:
```
1. Setup TidalProtocol position (like existing mirror tests)
2. Create UniswapV3SwapConnectors.Swapper for MOET/USDC
3. Execute incremental swaps (e.g., 20k MOET at a time)
4. For each swap:
   - Get quote (price before)
   - Execute swap
   - Measure actual output
   - Calculate slippage: (expected - actual) / expected
   - Calculate price impact: (price_after - price_before) / price_before
   - Log metrics
5. Continue until price impact > threshold OR slippage > max
6. Compare cumulative volume with simulation baseline (358k)
```

#### 3. Critical Functions to Use:

From `test_helpers_v3.cdc`:
```cadence
// Setup COA for EVM interaction
setupCOAForAccount(account, fundingAmount)

// Get MOET's EVM address after bridging
getEVMAddressForType(Type<@MOET.Vault>())

// Create v3 swapper
createV3Swapper(
    account: protocol,
    token0EVM: moetEVMAddr,
    token1EVM: usdcEVMAddr,
    token0Type: Type<@MOET.Vault>(),
    token1Type: Type<@USDC.Vault>(),
    feeTier: 3000  // 0.3%
)

// Log v3-specific metrics
logV3MirrorMetrics(testName, swapNumber, amountIn, amountOut, priceImpact, cumulativeVolume)
```

From `UniswapV3SwapConnectors`:
```cadence
// Get quote for swap
let quote = swapper.quoteOut(forProvided: amountIn, reverse: false)

// Execute swap
let vaultOut <- swapper.swap(quote: quote, inVault: <-vaultIn)
```

#### 4. Bridge Integration Pattern:

The test needs to handle Cadence ↔ EVM bridging:
```cadence
// Bridge MOET to EVM (needed once in setup)
// Use FlowEVMBridge contract's onboard functionality
// Then get EVM address via FlowEVMBridgeConfig

// For swaps, the UniswapV3SwapConnectors handles:
// - Cadence vault -> EVM token (via COA)
// - Execute swap on EVM
// - EVM token -> Cadence vault (via COA)
```

#### 5. Expected Output Logs:
```
MIRROR:test=rebalance_v3
MIRROR:swap_num=1
MIRROR:amount_in=20000.0
MIRROR:quote_out=19900.0
MIRROR:actual_out=19850.0
MIRROR:slippage=0.0025
MIRROR:price_impact=0.0015
MIRROR:cumulative_volume=20000.0
...
MIRROR:final_cumulative=354000.0
MIRROR:simulation_baseline=358000.0
MIRROR:difference_pct=0.011  # (358k-354k)/358k = 1.1%
```

### Implementation Challenges & Solutions

#### Challenge 1: EVM Environment Required
**Solution**: Test must check environment or fail gracefully:
```cadence
access(all) fun setup() {
    // Check if EVM bridge is available
    let bridgeAccountExists = // check bridge account
    if !bridgeAccountExists {
        log("SKIP: V3 integration test requires EVM environment")
        return
    }
    // ... proceed with setup
}
```

#### Challenge 2: Bridge Setup in Test
**Solution**: Either:
- **Option A**: Assume bridge setup is done externally (via `setup_bridged_tokens.sh`)
- **Option B**: Include bridge setup in test (more complex but self-contained)

Recommend **Option A** for first implementation.

#### Challenge 3: Pool Liquidity
**Solution**: 
- Use pool created by `setup_bridged_tokens.sh` (MOET/USDC with ~1000 MOET liquidity)
- OR create test-specific pool with known liquidity
- Document required liquidity in test comments

#### Challenge 4: Comparing with Simulation
**Solution**:
- Simulation used idealized conditions
- Real v3 will have different results due to:
  - Different pool liquidity
  - Different tick spacing
  - Real slippage accumulation
- Accept tolerance of 5-10% difference
- Log both values for analysis

### Test Structure Template

```cadence
import Test
import BlockchainHelpers

import "./test_helpers.cdc"
import "./test_helpers_v3.cdc"

import "FlowToken"
import "MOET"
import "TidalProtocol"
import "EVM"
import "FlowEVMBridgeConfig"
import "UniswapV3SwapConnectors"

access(all) let protocol = Test.getAccount(0x0000000000000008)

access(all) fun setup() {
    // 1. Deploy standard contracts
    deployContracts()
    
    // 2. Check EVM environment (fail gracefully if not available)
    // ...
    
    // 3. Setup COA for protocol account
    setupCOAForAccount(protocol, fundingAmount: 100.0)
    
    // 4. Setup TidalProtocol pool
    createAndStorePool(...)
    
    // 5. Open test position
    // ...
}

access(all) fun test_rebalance_capacity_real_v3() {
    // 1. Get MOET EVM address
    let moetEVMAddr = getEVMAddressForType(Type<@MOET.Vault>())
    let usdcEVMAddr = "0x..." // From deployed_addresses.env
    
    // 2. Create v3 swapper
    let swapper = createV3Swapper(
        account: protocol,
        token0EVM: moetEVMAddr,
        token1EVM: usdcEVMAddr,
        token0Type: Type<@MOET.Vault>(),
        token1Type: Type<@USDC.Vault>(),
        feeTier: 3000
    )
    
    // 3. Execute incremental swaps
    var cumulative: UFix64 = 0.0
    var swapNum: UInt64 = 0
    let stepSize: UFix64 = 20000.0
    let maxSlippage: UFix64 = 0.05  // 5%
    let simulationBaseline: UFix64 = 358000.0
    
    while cumulative < simulationBaseline {
        swapNum = swapNum + 1
        
        // Get quote (price before)
        let quote = swapper.quoteOut(forProvided: stepSize, reverse: false)
        let priceBefore = quote.outAmount / stepSize
        
        // Execute swap (need to implement actual swap execution)
        // This requires withdrawing MOET, bridging, swapping, bridging back
        // ...
        
        let actualOut: UFix64 = // ... get actual output
        
        // Calculate metrics
        let slippage = (quote.outAmount - actualOut) / quote.outAmount
        let priceAfter = actualOut / stepSize
        let priceImpact = (priceBefore - priceAfter) / priceBefore
        
        cumulative = cumulative + stepSize
        
        // Log metrics
        logV3MirrorMetrics("rebalance_v3", swapNum, stepSize, actualOut, priceImpact, cumulative)
        
        // Check exit conditions
        if slippage > maxSlippage {
            log("MIRROR:exit_reason=max_slippage_exceeded")
            break
        }
    }
    
    // Final comparison
    log("MIRROR:final_cumulative=".concat(cumulative.toString()))
    log("MIRROR:simulation_baseline=".concat(simulationBaseline.toString()))
    let diff = (simulationBaseline - cumulative) / simulationBaseline
    log("MIRROR:difference_pct=".concat(diff.toString()))
    
    // Assert within tolerance
    Test.assert(diff < 0.1)  // Within 10%
}
```

### Key Points for Implementation

1. **Start Simple**: First version can just quote and log, no actual swaps
2. **Incremental**: Add swap execution in second iteration
3. **Bridge Handling**: May need helper transaction for MOET vault → EVM → swap → EVM → vault flow
4. **Logging**: Comprehensive logging is critical for comparison
5. **Tolerance**: Accept 5-10% difference from simulation (different conditions)

### Files to Reference

1. **Existing MockV3 Test**: `cadence/tests/rebalance_liquidity_mirror_test.cdc` - See structure and assertions
2. **V3 Helpers**: `cadence/tests/test_helpers_v3.cdc` - Use these functions
3. **UniswapV3SwapConnectors**: `lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc` - See swap interface
4. **Simulation Results**: `lib/tidal-protocol-research/tidal_protocol_sim/results/Rebalance_Liquidity_Test/*.json` - Baseline values
5. **Bridge Examples**: `lib/flow-evm-bridge/cadence/tests/` - See how to use bridge

### Success Criteria

✅ Test runs successfully with EVM environment  
✅ Creates real v3 swapper  
✅ Executes quotes (minimum) or swaps (ideal)  
✅ Logs all numerical metrics  
✅ Compares with simulation baseline  
✅ Fails gracefully without EVM environment  
✅ Documents any differences from simulation  

### Additional Context

- **Memory**: User prefers numeric differences reported without judgment (just difference or percentage)
- **Branch**: Work on new branch, not main
- **Submodules**: DefiActions is now the preferred name over defiblocks

### Next Steps

1. Create `cadence/tests/rebalance_liquidity_v3_mirror_test.cdc` with at minimum quoting functionality
2. Test it runs with `flow test cadence/tests/rebalance_liquidity_v3_mirror_test.cdc`
3. Add actual swap execution if feasible
4. Create comparison report generator script
5. Port other mirror tests (depeg, flash crash) to v3

### Questions to Consider

1. Should test assume bridge setup is done externally, or do it internally?
2. What's acceptable tolerance for difference from simulation? (Recommend 5-10%)
3. Should we create dedicated test pool with known liquidity, or use existing?
4. How to handle swap execution - in test or via helper transaction?

---

**Start Here**: Begin with `cadence/tests/rebalance_liquidity_v3_mirror_test.cdc` that quotes prices and logs metrics. The infrastructure is ready - just need to wire it together!


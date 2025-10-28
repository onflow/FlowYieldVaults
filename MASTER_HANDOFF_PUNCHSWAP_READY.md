# Master Handoff: PunchSwap V3 Deployment Ready

**Date**: October 27, 2025  
**Branch**: `unit-zero-sim-integration-1st-phase`  
**Latest Commit**: `036593a`  
**Status**: 🚀 READY TO DEPLOY PUNCHSWAP V3

---

## 🎯 Where We Are

**User chose**: Option 1 - Deploy PunchSwap V3 now (~2 hours)

**Why**: Get REAL Uniswap V3 validation instead of MockV3 approximation

**All Prerequisites**: ✅ MET

---

## ✅ Complete Achievements Summary

### Investigation Complete (Phases 1-4)

**Mirror Validation**:
- ✅ All 3 scenarios investigated
- ✅ Gaps explained and documented
- ✅ Protocol math validated
- ✅ User's MOET logic confirmed correct
- ✅ MockV3 limitations discovered and documented

**Documentation**: 21 files, 6,000+ lines
- Master docs for fresh model context
- Complete investigation trail
- Honest assessments after user questions
- Integration plans and workflows

### EVM Integration Complete (Phase 5)

**Infrastructure**: ✅ 100% Working
- Flow emulator running with built-in EVM
- COA creation and interaction working
- Contract deployment tested
- **5/5 basic EVM tests PASSING!**

**Test Results** (`evm_coa_basic_test.cdc`):
```
✅ test_evm_contract_available
✅ test_create_coa
✅ test_get_coa_address (EVM address: 00000000000000000000000254981d0000000000)
✅ test_get_coa_balance
✅ test_deploy_minimal_contract
```

### Contracts Ready (Phase 6)

**MockERC20**: ✅ Compiled
- File: `solidity/contracts/MockERC20.sol`
- Bytecode: 10KB
- Ready for MOET and FLOW tokens

**PunchSwap V3**: ✅ Compiled
- Repository: [https://github.com/Kitty-Punch/punch-swap-v3-contracts](https://github.com/Kitty-Punch/punch-swap-v3-contracts) (official)
- Factory: 49KB bytecode
- SwapRouter: 20KB bytecode
- Pool: Deployed by factory

**Total Commits**: 14 pushed to branch

---

## 🚀 Deployment Plan (Next ~2 Hours)

### Phase 1: Deploy Mock Tokens (30 min) ⏳ NEXT

**Step 1a: Deploy MockMOET**
```bash
# Get bytecode
cd /Users/keshavgupta/tidal-sc/solidity
MOET_BYTECODE=$(jq -r '.bytecode.object' out/MockERC20.sol/MockERC20.json)

# Constructor args: ("Mock MOET", "MOET", 10000000 * 10**18)
# Need to ABI-encode constructor and append to bytecode

# Deploy
flow transactions send cadence/transactions/evm/deploy_simple_contract.cdc "$MOET_BYTECODE"
```

**Step 1b: Deploy MockFLOW**
- Same process, different symbol

**Step 1c: Save Addresses**
- Query deployed contract addresses
- Store for pool creation

### Phase 2: Deploy PunchSwap Factory (30 min)

**Step 2a: Get Factory Bytecode**
```bash
cd solidity/lib/punch-swap-v3-contracts
FACTORY_BYTECODE=$(jq -r '.bytecode.object' out/PunchSwapV3Factory.sol/PunchSwapV3Factory.json)
```

**Step 2b: Deploy Factory**
```bash
flow transactions send cadence/transactions/evm/deploy_simple_contract.cdc "$FACTORY_BYTECODE"
```

**Step 2c: Save Factory Address**

### Phase 3: Deploy SwapRouter (20 min)

**SwapRouter Constructor**:
- Needs: `address _factory, address _WETH9`
- Will need constructor arg encoding

**Deploy**:
```bash
ROUTER_BYTECODE=$(jq -r '.bytecode.object' out/SwapRouter.sol/SwapRouter.json)
# + encoded constructor args
flow transactions send cadence/transactions/evm/deploy_with_constructor.cdc "$FULL_BYTECODE"
```

### Phase 4: Create Pool (20 min)

**Create Cadence Transaction**: `call_factory_create_pool.cdc`
```cadence
import "EVM"

transaction(factoryAddr: String, token0: String, token1: String, fee: UInt24) {
    prepare(signer: auth(Storage) &Account) {
        let coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)!
        
        // Encode: createPool(address,address,uint24)
        let selector = "0xc9c65396"  // createPool function selector
        // Encode parameters...
        
        let factory = EVM.EVMAddress.fromString(factoryAddr)
        let result = coa.call(
            to: factory,
            data: encodedData,
            gasLimit: 5000000,
            value: EVM.Balance(attoflow: 0)
        )
        
        // Decode pool address from result
    }
}
```

**Execute**:
```bash
flow transactions send cadence/transactions/punchswap/create_pool.cdc \
  "$FACTORY" "$MOET" "$FLOW" 3000
```

### Phase 5: Initialize Pool & Add Liquidity (30 min)

**Initialize at 1:1 Price**:
```cadence
// Call pool.initialize(sqrtPriceX96)
// sqrtPriceX96 = 79228162514264337593543950336 for 1:1
```

**Add Concentrated Liquidity**:
```cadence
// Direct pool.mint() or via PositionManager
// tickLower: -120 (~1% below)
// tickUpper: 120 (~1% above)
// amount0: 500,000 MOET
// amount1: 500,000 FLOW
```

### Phase 6: Test Swap (20 min)

**Execute Swap**:
```cadence
// swapRouter.exactInputSingle({
//   tokenIn: MOET,
//   tokenOut: FLOW,
//   fee: 3000,
//   amountIn: 10000e18,
//   ...
// })
```

**Measure Results**:
```cadence
// Query pool.slot0() before and after
// Calculate:
// - Price impact
// - Actual slippage
// - Tick movement
```

**Compare to Simulation**:
```
Expected (from simulation JSON):
- Price impact: ~0.025%
- Slippage: ~0.0126%
- Tick change: 0 → 2-5

Our result: SHOULD MATCH!
```

### Phase 7: Create Comprehensive Tests (10 min)

**Test File**: `punchswap_v3_integration_test.cdc`
- Pool creation
- Liquidity addition
- Swap execution
- Price impact measurement
- Slippage calculation

### Phase 8: Replace MockV3 (10 min)

**Update One Mirror Test**:
- Replace MockV3 calls with PunchSwap calls
- Get real price dynamics
- Compare results

---

## 🔧 Technical Challenges

### Challenge 1: Constructor Args Encoding

**Issue**: ERC20 and SwapRouter need constructor arguments

**Solution**: Use `cast abi-encode` or implement in Cadence
```bash
# Encode ERC20 constructor
cast abi-encode "constructor(string,string,uint256)" \
  "Mock MOET" "MOET" "10000000000000000000000000"
```

### Challenge 2: ABI Encoding in Cadence

**Issue**: Need to encode function calls (createPool, swap, etc.)

**Solution**: Use `EVM.encodeABI` or pre-compute selectors
```cadence
// Function selector
let createPoolSelector: [UInt8] = [0xc9, 0xc6, 0x53, 0x96]

// Encode parameters (addresses, uint24)
// Concat all together
```

### Challenge 3: Result Decoding

**Issue**: Need to decode pool address, amounts, etc.

**Solution**: Use `EVM.decodeABI` or parse raw bytes
```cadence
let poolAddress = EVM.EVMAddress.fromBytes(result.data.slice(from: 12, upTo: 32))
```

---

## 📁 Files Status

### Working ✅:
- `cadence/transactions/evm/create_coa.cdc`
- `cadence/transactions/evm/deploy_simple_contract.cdc` (FIXED)
- `cadence/scripts/evm/get_coa_address.cdc`
- `cadence/scripts/evm/get_coa_balance.cdc`
- `cadence/tests/evm_coa_basic_test.cdc` (5/5 passing)

### Ready to Deploy ✅:
- `solidity/contracts/MockERC20.sol`
- `solidity/lib/punch-swap-v3-contracts/out/PunchSwapV3Factory.sol/PunchSwapV3Factory.json`
- `solidity/lib/punch-swap-v3-contracts/out/SwapRouter.sol/SwapRouter.json`

### To Create 📋:
- `cadence/transactions/evm/deploy_with_constructor.cdc` - For contracts with constructor args
- `cadence/transactions/punchswap/create_pool.cdc` - Call factory.createPool()
- `cadence/transactions/punchswap/initialize_pool.cdc` - Call pool.initialize()
- `cadence/transactions/punchswap/add_liquidity.cdc` - Add concentrated liquidity
- `cadence/transactions/punchswap/swap.cdc` - Execute swap
- `cadence/scripts/punchswap/get_pool_state.cdc` - Query slot0()
- `cadence/scripts/punchswap/calculate_price.cdc` - Convert sqrtPriceX96 to price
- `cadence/tests/punchswap_v3_integration_test.cdc` - Full integration test

---

## 💡 Quick Reference for Fresh Model

**Read First**:
1. `START_HERE_EXECUTIVE_SUMMARY.md` - Overview
2. `FINAL_HONEST_ASSESSMENT.md` - MockV3 truth
3. `READY_TO_DEPLOY_PUNCHSWAP.md` - Current status
4. `PUNCHSWAP_DEPLOYMENT_IN_PROGRESS.md` - This file

**Current Task**: Deploy PunchSwap V3

**Status**:
- Prerequisites: ✅ All met
- Contracts: ✅ All compiled
- Infrastructure: ✅ Working
- Next: Deploy tokens, then factory, then test!

**Estimated Time**: ~2 hours remaining

**Value**: TRUE Uniswap V3 validation

---

**Everything ready. Beginning deployment sequence now...** 🚀


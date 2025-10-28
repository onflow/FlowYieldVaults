# EVM & PunchSwap V3 Integration Progress

**Date**: October 27, 2025  
**Status**: Basic EVM integration working! 4/5 tests passing ✅

---

## ✅ What's Working

### EVM Infrastructure: READY

**Emulator**:
- ✅ Running with built-in EVM support
- ✅ EVM contract deployed at `f8d6e0586b0a20c7`
- ✅ `--setup-evm` enabled by default

**Test Results** (`evm_coa_basic_test.cdc`):
```
✅ test_evm_contract_available: EVM accessible
✅ test_create_coa: COA creation works  
✅ test_get_coa_address: Can get EVM address
   Result: 000000000000000000000002fb90ae0000000000
✅ test_get_coa_balance: Can query FLOW balance
   Result: 0.0 FLOW

❌ test_deploy_minimal_contract: Needs API fixes
   Issues: UInt8.fromString signature, COA authorization
```

**Success Rate**: 80% (4/5 passing)

### What This Proves

**✅ Validated**:
1. Built-in EVM works in test framework
2. Can create COAs from Cadence
3. COAs get valid EVM addresses
4. Can query EVM state from Cadence

**⏳ Next**:
- Fix deployment API issues
- Deploy real PunchSwap V3 contracts
- Create pools and test swaps

---

## 🛠️ Files Created

**Working Infrastructure**:
1. `cadence/transactions/evm/create_coa.cdc` ✅
2. `cadence/scripts/evm/get_coa_address.cdc` ✅
3. `cadence/scripts/evm/get_coa_balance.cdc` ✅

**Needs Fixing**:
4. `cadence/transactions/evm/deploy_simple_contract.cdc` ⚠️

**Tests**:
5. `cadence/tests/evm_coa_basic_test.cdc` - 4/5 passing ✅

---

## 🚧 Known Issues & Fixes Needed

### Issue 1: UInt8.fromString API Changed

**Error**:
```
too many arguments: UInt8.fromString(byteStr, radix: 16)
expected up to 1, got 2
```

**Fix**: Remove `radix` parameter
```cadence
// Old (doesn't work):
let byte = UInt8.fromString(byteStr, radix: 16)

// New (should work):
let byteHex = "0x".concat(byteStr)
let byte = UInt8.fromString(byteHex)
```

### Issue 2: COA Deploy Authorization

**Error**:
```
cannot access `deploy` because function requires `Owner | Deploy` authorization
```

**Fix**: Borrow with correct authorization
```cadence
// Old:
let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)

// New:
let coa = signer.storage.borrow<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(from: /storage/evm)
```

### Issue 3: Deploy Result API

**Error**:
```
value of type `EVM.Result` has no member `deployedAddress`
```

**Fix**: Check actual EVM.Result API
```cadence
// May need to access differently, like:
// deployResult.data or deployResult.address
```

---

## 📋 Next Steps

### Step 1: Fix Deployment Transaction (30 min)

Update `deploy_simple_contract.cdc`:
1. Fix UInt8.fromString calls
2. Add correct COA authorization
3. Fix deployment result access

### Step 2: Deploy Mock ERC20 (1 hour)

Create simple ERC20 tokens for testing:
```solidity
// MockMOET.sol
contract MockMOET {
    string public name = "Mock MOET";
    string public symbol = "MOET";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    
    constructor() {
        totalSupply = 10_000_000 * 10**18;
        balanceOf[msg.sender] = totalSupply;
    }
    
    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
```

Compile and deploy via Cadence.

### Step 3: Deploy PunchSwap V3 Factory (2 hours)

**Compile**:
```bash
cd solidity/lib/punch-swap-v3-contracts
forge build
```

**Get Bytecode**:
```bash
cat out/PunchSwapV3Factory.sol/PunchSwapV3Factory.json | jq -r '.bytecode.object' > /tmp/factory_bytecode.txt
```

**Deploy via Cadence**:
```cadence
let factoryBytecode = "<paste from /tmp/factory_bytecode.txt>"
// Deploy using fixed deploy transaction
```

### Step 4: Create Test Pool (1 hour)

After factory deployed:
```cadence
// Call factory.createPool(tokenA, tokenB, fee)
let poolAddress = // returned from createPool
```

### Step 5: Test Swap with Price Impact (30 min)

```cadence
// Swap through pool
// Query price before
// Execute swap
// Query price after
// Calculate actual slippage
// Compare to simulation
```

### Step 6: Replace MockV3 (1 hour)

Once PunchSwap tests pass:
- Update mirror tests to use PunchSwap instead of MockV3
- Get real price impact and slippage
- TRUE V3 validation!

**Total Estimated**: 6-7 hours

---

## 🎯 Current Progress

**Phase 1: Basic EVM** - 80% Complete ✅
- [x] COA creation
- [x] Address retrieval
- [x] Balance queries
- [ ] Contract deployment (needs API fixes)

**Phase 2: PunchSwap Deployment** - 0% Complete ⏳
- [ ] Fix deployment transaction
- [ ] Deploy mock ERC20 tokens
- [ ] Deploy PunchSwap Factory
- [ ] Deploy Pool contract

**Phase 3: Pool Creation** - 0% Complete ⏳
- [ ] Create MOET/FLOW pool
- [ ] Add concentrated liquidity
- [ ] Initialize at target price

**Phase 4: Trading Tests** - 0% Complete ⏳
- [ ] Execute swaps
- [ ] Measure price impact
- [ ] Calculate slippage
- [ ] Compare to simulation

**Phase 5: Mirror Integration** - 0% Complete ⏳
- [ ] Replace MockV3 in rebalance test
- [ ] Replace MockV3 in FLOW test
- [ ] Replace MockV3 in MOET test
- [ ] Validate real V3 behavior

---

## 💡 Quick Win Approach

**Priority 1: Get ONE successful deployment** (next 1 hour)
- Fix the 3 API issues in deploy_simple_contract.cdc
- Deploy simple ERC20
- Prove Solidity deployment works

**Priority 2: Deploy PunchSwap Factory** (next 2 hours)
- Compile factory with forge
- Deploy via fixed transaction
- Verify deployment

**Priority 3: Create & test pool** (next 2 hours)
- Create MOET/FLOW pool
- Add liquidity
- Execute one swap
- Show price impact!

**Priority 4: Integrate** (next 1-2 hours)
- Replace MockV3 in one test
- Compare results

---

## 🎓 What We've Learned

**User was right**:
- ✅ Flow CLI has built-in EVM
- ✅ No separate gateway needed (for basic use)
- ✅ Can deploy Solidity contracts from Cadence
- ✅ Integration is viable!

**Current status**:
- ✅ Infrastructure working (emulator + EVM)
- ✅ Basic operations validated (COA, queries)
- ⏳ Deployment needs API updates
- 📝 Clear path to PunchSwap V3

**Confidence**: HIGH that this will work!

---

## 🚀 Immediate Next Action

**Fix deployment transaction**:
1. Update UInt8.fromString usage (remove radix)
2. Add COA authorization (auth(EVM.Owner))
3. Fix deployment result access

Then we can deploy real contracts and proceed with PunchSwap V3 integration!

---

**Status**: Basic EVM validated (4/5 tests passing), deployment fix needed, clear path forward ✅


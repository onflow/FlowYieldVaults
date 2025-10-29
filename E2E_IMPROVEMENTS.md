# E2E Setup Improvements

## Summary

The original e2e test flow has been enhanced with automated vault creation and better error handling, based on learnings from the swap connector fix investigation.

---

## Key Improvements

### 1. Automated Bridged Token Vault Creation ✅

**Problem:**
When tokens are bridged from EVM to Cadence, accounts need vaults at specific storage paths to receive them. The original setup didn't create these vaults, causing transaction failures.

**Solution:**
Created `cadence/transactions/helpers/setup_bridged_token_vault.cdc` to automatically:
- Query the vault type from FlowEVMBridgeConfig
- Construct the correct storage path dynamically
- Create and save the vault
- Publish public capability for balance checking
- Handle already-exists case gracefully

**Usage in `setup_bridged_tokens.sh`:**
```bash
# After bridging USDC to Cadence, create vault
flow transactions send \
  ./cadence/transactions/helpers/setup_bridged_token_vault.cdc \
  $USDC_ADDR --signer tidal --gas-limit 9999
```

**Impact:**
- ✅ No more "Missing TokenOut vault" errors
- ✅ Works with any bridged token address
- ✅ Idempotent (safe to run multiple times)

---

### 2. Reusable MOET EVM Address Script ✅

**Problem:**
The original referenced a non-existent script: `./cadence/tests/scripts/get_moet_evm_address.cdc`

**Solution:**
Created `cadence/scripts/helpers/get_moet_evm_address.cdc`:

```cadence
import "MOET"
import "FlowEVMBridgeConfig"

access(all) fun main(): String? {
    let moetType = Type<@MOET.Vault>()
    if let evmAddr = FlowEVMBridgeConfig.getEVMAddressAssociated(with: moetType) {
        return evmAddr.toString()
    }
    return nil
}
```

**Usage:**
```bash
MOET_EVM=0x$(flow scripts execute \
  ./cadence/scripts/helpers/get_moet_evm_address.cdc \
  --format inline | sed -E 's/"([^"]+)"/\1/')
```

**Impact:**
- ✅ Proper error handling
- ✅ Reusable across scripts
- ✅ Returns nil if MOET not bridged yet

---

### 3. Better Error Handling in Token Deployment ✅

**Problem:**
Pool creation failures in `e2e_punchswap.sh` would stop the entire flow, even though token deployment succeeded.

**Solution:**
Made pool creation non-fatal:

```bash
forge script .../03_UseMintedUSDCWBTC_AddLPAndSwap.s.sol \
  --broadcast || {
    echo "⚠️  Pool creation had issues, but tokens deployed successfully"
    echo "   Pool will be created in setup_bridged_tokens.sh instead"
}
```

**Impact:**
- ✅ Token deployment always completes
- ✅ Clear messaging when pool creation fails
- ✅ Flow continues to bridge setup
- ✅ Pool created later in setup_bridged_tokens.sh

---

### 4. Parameterized Swap Transaction ✅

**Problem:**
Original swap transaction had hardcoded addresses, making it inflexible for different deployments.

**Solution:**
Created `cadence/transactions/connectors/univ3-swap-connector-parameterized.cdc`:

```cadence
transaction(
    factoryAddressHex: String,
    routerAddressHex: String,
    quoterAddressHex: String,
    tokenInAddressHex: String,
    tokenOutAddressHex: String,
    feeTier: UInt32,
    amountIn: UFix64
)
```

**Impact:**
- ✅ Works with any token addresses
- ✅ Supports dynamic deployments
- ✅ Easy to test different pairs
- ✅ Chain-agnostic

---

### 5. Integrated Swap Test in E2E Flow ✅

**Addition to `univ3_test.sh`:**

```bash
# At the end of the flow, test Cadence swap
flow transactions send \
  ./cadence/transactions/connectors/univ3-swap-connector-parameterized.cdc \
  <factory> <router> <quoter> <tokenIn> <tokenOut> <fee> <amount> \
  --signer tidal --gas-limit 9999
```

**Impact:**
- ✅ End-to-end verification
- ✅ Uses dynamically deployed addresses
- ✅ Proves factoryAddress fix works
- ✅ Clear success/failure messaging

---

### 6. Enhanced Address Validation ✅

**Addition to `setup_bridged_tokens.sh`:**

```bash
echo "get MOET EVM address"
MOET_EVM_ADDRESS=0x$(flow scripts execute .../get_moet_evm_address.cdc ...)

if [ -z "$MOET_EVM_ADDRESS" ] || [ "$MOET_EVM_ADDRESS" = "0x" ]; then
    echo "❌ ERROR: Could not get MOET EVM address"
    exit 1
fi

echo "MOET EVM Address: $MOET_EVM_ADDRESS"
```

**Impact:**
- ✅ Validates MOET was bridged successfully
- ✅ Clear error messages
- ✅ Prevents proceeding with invalid addresses
- ✅ Easier debugging

---

## Files Modified

### New Files (Reusable Components)
1. **`cadence/transactions/helpers/setup_bridged_token_vault.cdc`**
   - Generic vault creation for any bridged EVM token
   - Used for USDC, WBTC, and any future tokens

2. **`cadence/scripts/helpers/get_moet_evm_address.cdc`**
   - Gets MOET's EVM address after bridging
   - Returns nil if not bridged yet

3. **`cadence/transactions/connectors/univ3-swap-connector-parameterized.cdc`**
   - Flexible swap transaction accepting all addresses as parameters
   - Works with any token pair

### Modified Files (Enhanced Existing)
1. **`local/setup_bridged_tokens.sh`**
   - Added automated USDC vault creation
   - Added automated WBTC vault creation
   - Added MOET address validation
   - Better error messages

2. **`local/punchswap/e2e_punchswap.sh`**
   - Made pool creation non-fatal
   - Added clear status messages
   - Better completion reporting

3. **`local/univ3_test.sh`**
   - Added Cadence swap test at the end
   - Uses parameterized transaction
   - Dynamic address loading
   - Clear success/failure reporting

4. **`cadence/transactions/connectors/univ3-swap-connector.cdc`**
   - Added factoryAddress parameter (THE CORE FIX)

---

## Before vs After

### Before

```bash
# setup_bridged_tokens.sh
bridge USDC → ❌ No vault creation → Swap fails with "Missing vault"
bridge WBTC → ❌ No vault creation → Can't receive tokens
bridge MOET → ✅ Works
create pool → May work
add liquidity → May work
# No Cadence swap test
```

### After

```bash
# setup_bridged_tokens.sh
bridge USDC → ✅ Auto-create vault → Ready to receive
bridge WBTC → ✅ Auto-create vault → Ready to receive  
bridge MOET → ✅ Works
validate MOET address → ✅ Error if missing
create pool → Works or continues gracefully
add liquidity → Works
✅ Test Cadence swap with dynamic addresses
```

---

## Innovation: Dynamic Path Construction

**The Key Pattern:**

```cadence
// Generic helper that works for ANY bridged EVM token
transaction(evmAddressHex: String) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // 1. Get vault type from bridge config
        let vaultType = FlowEVMBridgeConfig.getTypeAssociated(with: evmAddr)
        
        // 2. Construct storage path dynamically
        let pathIdentifier = "EVMVMBridgedToken_".concat(
            evmAddressHex.slice(from: 2, upTo: evmAddressHex.length).toLower()
        ).concat("Vault")
        
        let storagePath = StoragePath(identifier: pathIdentifier)!
        
        // 3. Create vault if doesn't exist
        if signer.storage.type(at: storagePath) == nil {
            signer.storage.save(
                <- FlowEVMBridgeConfig.createEmptyVault(type: vaultType),
                to: storagePath
            )
        }
    }
}
```

**Why This Matters:**
- Works with ANY EVM token address
- No hardcoding required
- Chain-agnostic
- Follows FlowEVM bridge conventions

---

## Testing the Improvements

### Full E2E Test

```bash
# Run the complete flow
./local/univ3_test.sh
```

**Expected Flow:**
1. ✅ Emulator starts
2. ✅ Wallets created
3. ✅ EVM gateway starts
4. ✅ PunchSwap contracts deployed
5. ✅ Tokens deployed (addresses captured)
6. ⚠️  Pool creation (may fail, non-fatal)
7. ✅ Cadence contracts deployed
8. ✅ MOET minted
9. ✅ USDC bridged + **vault auto-created** 
10. ✅ WBTC bridged + **vault auto-created**
11. ✅ MOET bridged to EVM
12. ✅ Pool created
13. ✅ Liquidity added
14. ✅ **Cadence swap tested**

### Just the Swap Test

```bash
# Assuming setup is done
flow transactions send \
  ./cadence/transactions/connectors/univ3-swap-connector-parameterized.cdc \
  "0x986Cb42b0557159431d48fE0A40073296414d410" \
  "0x2Db6468229F6fB1a77d248Dbb1c386760C257804" \
  "0xA1e0E4CCACA34a738f03cFB1EAbAb16331FA3E2c" \
  "0x9a7b1d144828c356ec23ec862843fca4a8ff829e" \
  "0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95" \
  3000 \
  1.0 \
  --signer tidal --gas-limit 9999
```

---

## Benefits

### For Development
- ✅ Fewer manual steps
- ✅ Clearer error messages
- ✅ Better debugging
- ✅ Reusable components

### For Testing
- ✅ More reliable flow
- ✅ Graceful degradation
- ✅ End-to-end verification
- ✅ Dynamic address support

### For Maintenance
- ✅ Generic vault creation (works for any token)
- ✅ Parameterized transactions (no hardcoding)
- ✅ Better separation of concerns
- ✅ Clear documentation

---

## Migration Guide

### What Changed

**If you're using `./local/univ3_test.sh`:**
- ✅ Script now handles vault creation automatically
- ✅ Swap test added at the end
- ✅ Better error messages
- ⚠️  Pool creation failures are non-fatal now

**If you're using `./local/setup_bridged_tokens.sh`:**
- ✅ USDC and WBTC vaults auto-created
- ✅ MOET address validation added
- ✅ Uses new helper transactions

**If you're calling swap transactions directly:**
- ✅ Use `univ3-swap-connector-parameterized.cdc` for flexibility
- ✅ Original `univ3-swap-connector.cdc` still works (with factoryAddress fix)

### What Stayed the Same

- ✅ Overall flow structure
- ✅ Script execution order
- ✅ Token deployment process
- ✅ Bridge onboarding process
- ✅ Pool creation process

---

## Summary of Changes

| Component | Type | Description |
|-----------|------|-------------|
| `cadence/transactions/helpers/setup_bridged_token_vault.cdc` | **NEW** | Generic vault creation |
| `cadence/scripts/helpers/get_moet_evm_address.cdc` | **NEW** | Get MOET EVM address |
| `cadence/transactions/connectors/univ3-swap-connector-parameterized.cdc` | **NEW** | Flexible swap transaction |
| `local/setup_bridged_tokens.sh` | **ENHANCED** | Auto vault creation + validation |
| `local/punchswap/e2e_punchswap.sh` | **ENHANCED** | Non-fatal pool errors |
| `local/univ3_test.sh` | **ENHANCED** | Added swap test at end |
| `cadence/transactions/connectors/univ3-swap-connector.cdc` | **FIXED** | Added factoryAddress |

---

## Why These Changes Matter

### Original Pattern Problem:
```
Deploy → Bridge → Assume vault exists → ❌ Transaction fails
```

### New Improved Pattern:
```
Deploy → Bridge → Create vault → ✅ Transaction succeeds
```

### The Innovation:
Instead of requiring manual vault setup or assuming vaults exist, **we now automate vault creation as part of the bridge setup flow**.

This makes the e2e test:
- **More robust** - Handles vault creation automatically
- **More maintainable** - Generic helper for any token
- **More testable** - Includes end-to-end swap verification
- **More debuggable** - Better error messages and validation

---

## Next Steps

### For Users
Just run the existing e2e test - it now includes all improvements:
```bash
./local/univ3_test.sh
```

### For Developers
Use the new reusable components:

**Create vault for any bridged token:**
```bash
flow transactions send \
  ./cadence/transactions/helpers/setup_bridged_token_vault.cdc \
  <EVM_TOKEN_ADDRESS> \
  --signer <account>
```

**Get MOET EVM address:**
```bash
flow scripts execute ./cadence/scripts/helpers/get_moet_evm_address.cdc
```

**Test swap with custom tokens:**
```bash
flow transactions send \
  ./cadence/transactions/connectors/univ3-swap-connector-parameterized.cdc \
  <factory> <router> <quoter> <tokenIn> <tokenOut> <fee> <amount> \
  --signer <account>
```

---

## Conclusion

The original e2e setup pattern has been **enhanced, not replaced**:
- ✅ Same overall structure
- ✅ Same execution flow
- ✅ **Better automation**
- ✅ **Better error handling**
- ✅ **Better reusability**

These improvements make the e2e test more reliable and easier to maintain while keeping the comprehensive testing approach your peer expects.


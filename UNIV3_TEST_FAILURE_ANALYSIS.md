# univ3_test.sh Failure Analysis - Exact File References

## Root Cause: Chain ID Mismatch

**Current Setup:**
- **Gateway running**: Chain ID **545** (preview network)
- **Configs expect**: Chain ID **646** (testnet network)
- **Result**: CREATE2 addresses don't match, causing all downstream failures

---

## File Locations & Issues

### 1. Gateway Configuration

**File:** `local/run_evm_gateway.sh`
**Line 10:** 
```bash
--evm-network-id=preview \
```

**Issue:** This sets chain ID to **545**, but all other configs expect **646**

**Chain ID Reference:**
- `preview` = Chain ID 545
- `testnet` = Chain ID 646

---

### 2. Hardcoded Token Addresses (Wrong for Chain 545)

**File:** `local/punchswap/punchswap.env`

**Lines 33-34:**
```bash
USDC_ADDR=0xaCCF0c4EeD4438Ad31Cd340548f4211a465B6528
WBTC_ADDR=0x374BF2423c6b67694c068C3519b3eD14d3B0C5d1
```

**Issue:** These addresses were calculated for chain ID 646, not 545. CREATE2 deployment will produce different addresses on chain 545.

---

### 3. Bridge Setup Script Using Wrong Addresses

**File:** `local/setup_bridged_tokens.sh`

**Lines 1-5:**
```bash
# bridge USDC
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0xaCCF0c4EeD4438Ad31Cd340548f4211a465B6528 --signer emulator-account --gas-limit 9999

# bridge WBTC 
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x374BF2423c6b67694c068C3519b3eD14d3B0C5d1 --signer emulator-account --gas-limit 9999
```

**Issue:** Tries to bridge tokens at addresses that don't exist (or are at different addresses) on chain 545.

**Error in log (line 2530-2710):**
```
error: failed to ABI decode data
  --> f8d6e0586b0a20c7.FlowEVMBridgeUtils:156:28
```

---

### 4. E2E Test Script

**File:** `local/punchswap/e2e_punchswap.sh`

**Lines 7-12:**
```bash
forge script ./solidity/script/02_DeployUSDC_WBTC_Create2.s.sol:DeployUSDC_WBTC_Create2 \
  --rpc-url $RPC_URL --broadcast -vvvv --slow

forge script ./solidity/script/03_UseMintedUSDCWBTC_AddLPAndSwap.s.sol:UseMintedUSDCWBTC \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvvv --slow --via-ir
```

**First script succeeds** (deploys tokens via CREATE2), but **second script fails**.

---

### 5. CREATE2 Deployment Script

**File:** `solidity/script/02_DeployUSDC_WBTC_Create2.s.sol`

**Lines 9-14:**
```solidity
contract DeployUSDC_WBTC_Create2 is Script {
    // Foundry's CREATE2 deployer used during broadcast
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Fixed salts → stable addresses for a given initcode
    bytes32 constant SALT_USDC = keccak256("FLOW-USDC-001");
    bytes32 constant SALT_WBTC = keccak256("FLOW-WBTC-001");
```

**Lines 25-26:**
```solidity
address predictedUSDC = _predict(CREATE2_DEPLOYER, SALT_USDC, usdcInit);
address predictedWBTC = _predict(CREATE2_DEPLOYER, SALT_WBTC, wbtcInit);
```

**Issue:** CREATE2 addresses are deterministic based on:
- Deployer address
- Salt
- Init code (including constructor args which include chain ID in some cases)

The **actual deployed addresses** on chain 545 differ from what's configured.

**Log Evidence (line 2005-2007):**
```
Predicted USDC: 0x17ed9461059f6a67612d5fAEf546EB3487C9544D
Predicted WBTC: 0xeA6005B036A53Dd8Ceb8919183Fc7ac9E7bDC86E
```

These are **DIFFERENT** from the hardcoded addresses in `punchswap.env`!

---

### 6. Swap Script Failure

**File:** `solidity/script/03_UseMintedUSDCWBTC_AddLPAndSwap.s.sol`

**Lines 150-152:**
```solidity
// Predeployed token addresses from your CREATE2 step
address USDC = vm.envAddress("USDC_ADDR");
address WBTC = vm.envAddress("WBTC_ADDR");
```

**Lines 199-200:**
```solidity
_ensureFunded(t0, eoa, amt0, (t0 == USDC) ? usdcMint : wbtcMint, TRY_MINT);
_ensureFunded(t1, eoa, amt1, (t1 == WBTC) ? wbtcMint : usdcMint, TRY_MINT);
```

**Lines 119-120 (in _ensureFunded):**
```solidity
uint256 have = IERC20(token).balanceOf(holder);
if (have >= need) return;
```

**Issue:** Calls `balanceOf()` on the wrong token address (from env), gets empty response, script reverts.

**Log Evidence (line 2130-2136):**
```
├─ [0] 0x374BF2423c6b67694c068C3519b3eD14d3B0C5d1::balanceOf(0xC31A5268a1d311d992D637E8cE925bfdcCEB4310) [staticcall]
│   └─ ← [Stop]
└─ ← [Revert] EvmError: Revert

Error: script failed: <empty revert data>
```

---

## How Chain ID Affects CREATE2

CREATE2 address calculation:
```
address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))
```

Even though the formula doesn't include chain ID directly, the `initCode` includes:
1. Contract bytecode (may vary by chain)
2. Constructor arguments (may include chain-dependent values)
3. Compiler settings that reference chain ID

This is why the same salt produces different addresses on different chains.

**Proof from logs:**

**Simulation on Chain 646 (line 2067):**
```
Chain 646
Estimated gas price: 0.000000003 gwei
```

**Actual addresses deployed (different from config):**
- Config USDC: `0xaCCF0c4EeD4438Ad31Cd340548f4211a465B6528`
- Actual USDC: `0x17ed9461059f6a67612d5fAEf546EB3487C9544D` ⚠️ **MISMATCH**

---

## Solutions (Pick One)

### Solution A: Change Gateway to Chain 646 (Simplest)

**File:** `local/run_evm_gateway.sh`
**Line 10:** Change from:
```bash
--evm-network-id=preview \
```
To:
```bash
--evm-network-id=testnet \
```

**Pro:** No other changes needed, matches all existing configs
**Con:** Preview network won't be tested

---

### Solution B: Update All Configs for Chain 545

**Step 1:** Run token deployment in dry-run on chain 545 to get actual addresses

**Step 2:** Update `local/punchswap/punchswap.env` lines 33-34 with actual addresses

**Step 3:** Update `local/setup_bridged_tokens.sh` lines 2 and 5 with actual addresses

**Pro:** Tests preview network properly
**Con:** Requires re-running deployment to capture addresses, more error-prone

---

### Solution C: Make Scripts Dynamic

**Modify:** `local/punchswap/e2e_punchswap.sh` to:
1. Capture actual deployed addresses from script 02 output
2. Export them as env vars
3. Use those in script 03 instead of hardcoded env file

**Example:**
```bash
# Capture addresses from deployment
DEPLOY_OUTPUT=$(forge script ./solidity/script/02_DeployUSDC_WBTC_Create2.s.sol:DeployUSDC_WBTC_Create2 \
  --rpc-url $RPC_URL --broadcast -vvvv --slow 2>&1)

# Extract addresses (needs parsing)
ACTUAL_USDC=$(echo "$DEPLOY_OUTPUT" | grep "Deployed USDC" | awk '{print $4}')
ACTUAL_WBTC=$(echo "$DEPLOY_OUTPUT" | grep "Deployed WBTC" | awk '{print $4}')

# Export for next script
export USDC_ADDR=$ACTUAL_USDC
export WBTC_ADDR=$ACTUAL_WBTC
```

**Pro:** Works on any chain ID, most robust
**Con:** Requires more script changes

---

## Recommended Fix

**Use Solution A** - it's the quickest and matches the existing infrastructure:

```bash
cd /Users/keshavgupta/tidal-sc
# Edit local/run_evm_gateway.sh line 10
# Change: --evm-network-id=preview
# To:     --evm-network-id=testnet
```

This will make the gateway use chain ID 646, matching all the hardcoded addresses and configurations.

---

## Test to Verify Fix

After applying Solution A, rerun:
```bash
bash local/univ3_test.sh > univ3_test_output.log 2>&1
```

Expected success indicators:
1. No "script failed: <empty revert data>" errors
2. No "failed to ABI decode data" errors
3. Script completes pool creation and swap
4. Token bridging succeeds


# UniswapV3 Swap Connector Fix - Emulator Issue Resolution

## Problem Summary

The UniswapV3 swap transaction from Cadence was failing on the emulator, while direct EVM transactions using `cast` were working correctly.

**Client Report:**
> "I can swap MOET for USDC using cast, but the same swap transaction doesn't work from cadence"

**Symptoms:**
- `cast send` commands to the Uniswap router worked fine
- Cadence transactions using `UniswapV3SwapConnectors.Swapper` failed
- Pool creation, approvals, and liquidity addition all worked via cast
- Same code worked on testnet but not on emulator

## Root Cause

The transaction file `cadence/transactions/connectors/univ3-swap-connector.cdc` was missing the required `factoryAddress` parameter when initializing the `UniswapV3SwapConnectors.Swapper`.

This parameter is required by the Swapper to query pool information (reserves, liquidity, tick data) before executing swaps.

### Code Issue

**Before (Broken):**
```cadence
let swapper = UniswapV3SwapConnectors.Swapper(
    routerAddress: router,
    quoterAddress: quoter,
    tokenPath: [tokenIn, tokenOut],
    feePath: [3000],
    inVault: inType,
    outVault: outType,
    coaCapability: coaCap,
    uniqueID: nil
)
```

**After (Fixed):**
```cadence
let factory = EVM.addressFromString("0x986Cb42b0557159431d48fE0A40073296414d410")

let swapper = UniswapV3SwapConnectors.Swapper(
    factoryAddress: factory,  // ← ADDED THIS
    routerAddress: router,
    quoterAddress: quoter,
    tokenPath: [tokenIn, tokenOut],
    feePath: [3000],
    inVault: inType,
    outVault: outType,
    coaCapability: coaCap,
    uniqueID: nil
)
```

## Why This Happened

The `UniswapV3SwapConnectors.Swapper` struct was recently updated (in the nialexsan/add-v3-to-strategy branch) to require a `factoryAddress` parameter. This parameter is used internally by the connector to:

1. Query pool information via `getPool(address,address,uint24)`
2. Read pool state (slot0, liquidity, tickBitmap, etc.)
3. Calculate maximum swap amounts to prevent pool exhaustion

The `TidalYieldStrategies.cdc` contract was updated correctly to include this parameter, but the test transaction file was not updated, causing it to fail at runtime.

## Solution

Updated `cadence/transactions/connectors/univ3-swap-connector.cdc` to include the factory address:
- **Factory Address:** `0x986Cb42b0557159431d48fE0A40073296414d410`
- This address comes from the PunchSwap V3 deployment on the emulator (see `local/punchswap/flow-emulator.json`)

## Files Changed

1. **`cadence/transactions/connectors/univ3-swap-connector.cdc`**
   - Added `factoryAddress` parameter to Swapper initialization
   - Factory address: `0x986Cb42b0557159431d48fE0A40073296414d410`

## Testing

### Quick Test (Verify Fix Works)

```bash
flow transactions send ./cadence/transactions/connectors/univ3-swap-connector.cdc --signer tidal --gas-limit 9999
```

Expected: Transaction passes Swapper initialization (may fail later due to missing pool/liquidity, which is fine)

### Full E2E Test (Complete Verification)

```bash
# Run the complete enhanced e2e flow
./local/univ3_test.sh
```

This now includes:
- All original setup steps
- Automated vault creation for bridged tokens
- Cadence swap test at the end
- Better error handling throughout

See `E2E_IMPROVEMENTS.md` for details on what was enhanced.

## Why Cast Worked But Cadence Didn't

- **Cast commands** directly call the Uniswap router's `exactInput` function with pre-computed calldata
- **Cadence connector** needs the factory address to:
  - Query pool reserves and state before executing swaps
  - Calculate safe swap amounts to avoid reverting transactions
  - Validate the swap path and pool existence

Without the factory address, the Cadence code couldn't query pool information, causing the transaction to fail before even reaching the router.

## E2E Setup Enhancements

As part of fixing this issue, the original e2e setup was enhanced with several innovations:

1. **Automated Vault Creation** - `cadence/transactions/helpers/setup_bridged_token_vault.cdc`
   - Automatically creates vaults for bridged EVM tokens
   - Integrated into `setup_bridged_tokens.sh`

2. **Reusable Helper Scripts** - `cadence/scripts/helpers/get_moet_evm_address.cdc`
   - Gets MOET's EVM address after bridging
   - Proper error handling

3. **Parameterized Swap Transaction** - `cadence/transactions/connectors/univ3-swap-connector-parameterized.cdc`
   - Accepts all addresses as parameters for flexibility
   - Works with any token pair

See `E2E_IMPROVEMENTS.md` for complete details.

## Related Files

- `lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc` - Connector implementation
- `cadence/contracts/TidalYieldStrategies.cdc` - Already had the fix applied
- `local/punchswap/flow-emulator.json` - Contains deployed contract addresses
- `E2E_IMPROVEMENTS.md` - Documents all e2e setup enhancements

## Additional Notes

The `TidalYieldStrategies` contract already uses the factory address correctly:
- It stores factory/router/quoter addresses as contract-level constants
- It passes these to swapper instances when creating strategies
- The standalone transaction file just needed to be updated to match this pattern

## Chain ID Context

The emulator setup uses:
- **Flow Network ID:** `emulator`
- **EVM Network ID:** `preview` (Chain ID: 646)
- **EVM Gateway:** Running on `http://localhost:8545`

The dynamic address management system ensures token addresses work correctly across different chain IDs (see `local/README_DYNAMIC_ADDRESSES.md`).


# UniswapV3 Swap Connector Fix - Emulator Issue Resolution

## Problem Summary

The UniswapV3 swap transaction from Cadence was failing on the emulator, while direct EVM transactions using `cast` were working correctly.

**Symptoms:**
- `cast send` commands to the Uniswap router worked fine
- Cadence transactions using `UniswapV3SwapConnectors.Swapper` failed
- Pool creation, approvals, and liquidity addition all worked via cast
- Same code worked on testnet but not on emulator

## Root Cause

The transaction file `cadence/transactions/connectors/univ3-swap-connector.cdc` was missing the required `factoryAddress` parameter when initializing the `UniswapV3SwapConnectors.Swapper`.

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

To test the fix:

```bash
# Make sure emulator and EVM gateway are running
./local/run_emulator.sh
./local/run_evm_gateway.sh

# Run the setup scripts
./local/setup_emulator.sh
./local/punchswap/setup_punchswap.sh
./local/punchswap/e2e_punchswap.sh
./local/setup_bridged_tokens.sh

# Test the swap
./local/test_swap_fix.sh
```

Or test directly:
```bash
flow transactions send ./cadence/transactions/connectors/univ3-swap-connector.cdc --signer tidal --gas-limit 9999
```

## Why Cast Worked But Cadence Didn't

- **Cast commands** directly call the Uniswap router's `exactInput` function with pre-computed calldata
- **Cadence connector** needs the factory address to:
  - Query pool reserves and state before executing swaps
  - Calculate safe swap amounts to avoid reverting transactions
  - Validate the swap path and pool existence

Without the factory address, the Cadence code couldn't query pool information, causing the transaction to fail before even reaching the router.

## Related Files

- `lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc` - Connector implementation
- `cadence/contracts/TidalYieldStrategies.cdc` - Already had the fix applied
- `local/punchswap/flow-emulator.json` - Contains deployed contract addresses

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


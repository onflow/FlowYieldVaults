# Quick Fix Reference - Chain ID Mismatch

## The Problem in 3 Lines

1. Gateway runs on chain ID **545** (preview) - `local/run_evm_gateway.sh:10`
2. All configs expect chain ID **646** (testnet) - `local/punchswap/punchswap.env:33-34`
3. CREATE2 produces different addresses per chain → everything breaks

## The Evidence

**Config says tokens at:**
- USDC: `0xaCCF0c4EeD4438Ad31Cd340548f4211a465B6528`
- WBTC: `0x374BF2423c6b67694c068C3519b3eD14d3B0C5d1`

**Actually deployed at (on chain 545):**
- USDC: `0x17ed9461059f6a67612d5fAEf546EB3487C9544D` ← See log line 2005
- WBTC: `0xeA6005B036A53Dd8Ceb8919183Fc7ac9E7bDC86E` ← See log line 2006

## The Fix (1 line change)

**File:** `local/run_evm_gateway.sh`  
**Line:** 10  
**Change:**
```diff
- --evm-network-id=preview \
+ --evm-network-id=testnet \
```

This changes chain ID from 545 → 646, matching all the configs.

## Files Affected by This Bug

| File | Line(s) | Issue |
|------|---------|-------|
| `local/run_evm_gateway.sh` | 10 | Sets wrong chain ID (545) |
| `local/punchswap/punchswap.env` | 33-34 | Hardcoded addresses for chain 646 |
| `local/setup_bridged_tokens.sh` | 2, 5 | Tries to bridge non-existent addresses |
| `solidity/script/03_UseMintedUSDCWBTC_AddLPAndSwap.s.sol` | 150-152 | Reads wrong addresses from env |

## Error Locations in Log

| Log Line | Error | Cause |
|----------|-------|-------|
| 2136 | `script failed: <empty revert data>` | Called `balanceOf()` on wrong address |
| 2530-2710 | `failed to ABI decode data` | Tried to bridge non-existent token |

## Share This With Your Colleague

"We have a chain ID mismatch: the gateway runs on chain 545 (preview) but all our configs assume chain 646 (testnet). This causes CREATE2 to deploy tokens at different addresses than expected, so everything downstream fails. Quick fix: change line 10 in `local/run_evm_gateway.sh` from `--evm-network-id=preview` to `--evm-network-id=testnet`"

## Detailed Analysis

See: `UNIV3_TEST_FAILURE_ANALYSIS.md` for complete breakdown with all file references.


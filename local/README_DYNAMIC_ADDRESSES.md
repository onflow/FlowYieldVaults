# Dynamic Address Management for Chain-Agnostic Testing

## Problem Solved

Previously, token addresses were **hardcoded** in `punchswap.env`, causing issues when:
- Running on different chain IDs
- CREATE2 deployments producing different addresses per chain
- Manual address updates required after each deployment

## Solution: Dynamic Address Capture

The test scripts now **automatically capture and use** actual deployed addresses, making the entire flow chain-agnostic.

---

## How It Works

### 1. Deployment Phase (`e2e_punchswap.sh`)

```bash
# Deploy tokens and capture output
DEPLOY_OUTPUT=$(forge script .../02_DeployUSDC_WBTC_Create2.s.sol ...)

# Extract actual addresses from logs
ACTUAL_USDC=$(echo "$DEPLOY_OUTPUT" | grep "Deployed USDC at" | ...)
ACTUAL_WBTC=$(echo "$DEPLOY_OUTPUT" | grep "Deployed WBTC at" | ...)

# Export for immediate use
export USDC_ADDR=$ACTUAL_USDC
export WBTC_ADDR=$ACTUAL_WBTC

# Save to file for bridge setup
cat > ./local/deployed_addresses.env << EOF
USDC_ADDR=$ACTUAL_USDC
WBTC_ADDR=$ACTUAL_WBTC
EOF
```

### 2. Usage Phase (`setup_bridged_tokens.sh`)

```bash
# Load dynamically captured addresses
if [ -f ./local/deployed_addresses.env ]; then
    source ./local/deployed_addresses.env
else
    # Fallback to static config
    source ./local/punchswap/punchswap.env
fi

# Use the addresses
flow transactions send ... $USDC_ADDR ...
flow transactions send ... $WBTC_ADDR ...
```

---

## File Structure

### Static Config (committed to repo)
```
local/punchswap/punchswap.env
├─ USDC_ADDR=0x...  ← Reference/fallback addresses
└─ WBTC_ADDR=0x...
```

### Dynamic Config (auto-generated, ignored by git)
```
local/deployed_addresses.env
├─ USDC_ADDR=0x...  ← Actual deployed addresses
└─ WBTC_ADDR=0x...  ← Captured from deployment output
```

---

## Benefits

### ✅ Chain Agnostic
Works on any chain ID without modification:
- Chain 545 (Flow Testnet)
- Chain 646 (Current setup)
- Chain 747 (Flow Mainnet)
- Any future chain

### ✅ Zero Manual Updates
No need to:
- Update configs after deployment
- Match addresses between files
- Remember to sync addresses

### ✅ Fail-Safe
- Validates addresses are captured
- Falls back to static config if needed
- Errors clearly if addresses missing

### ✅ Auditable
- `deployed_addresses.env` shows what was actually used
- Can verify addresses match deployment logs
- Easy debugging when issues occur

---

## Usage

### Running Tests (Automatic)
```bash
# Just run the test - addresses handled automatically
bash local/univ3_test.sh
```

The flow:
1. ✅ Emulator starts
2. ✅ Tokens deploy → addresses captured → saved to `deployed_addresses.env`
3. ✅ Pool/swap test uses captured addresses
4. ✅ Bridge setup uses captured addresses
5. ✅ Everything works regardless of chain!

### Manual Token Deployment
```bash
# Deploy tokens
bash local/punchswap/e2e_punchswap.sh

# Check captured addresses
cat local/deployed_addresses.env

# Output:
# USDC_ADDR=0x17ed9461059f6a67612d5fAEf546EB3487C9544D
# WBTC_ADDR=0xeA6005B036A53Dd8Ceb8919183Fc7ac9E7bDC86E
```

### Cleaning Up
```bash
# Remove auto-generated file to force fresh deployment
rm local/deployed_addresses.env

# Next run will create new addresses
bash local/univ3_test.sh
```

---

## Implementation Details

### Address Extraction Logic

```bash
# Primary: Look for "Deployed X at 0x..."
ACTUAL_USDC=$(echo "$OUTPUT" | grep -i "Deployed USDC at" | grep -o '0x[a-fA-F0-9]\{40\}')

# Fallback: Look for "Predicted X: 0x..."
if [ -z "$ACTUAL_USDC" ]; then
    ACTUAL_USDC=$(echo "$OUTPUT" | grep -i "Predicted USDC:" | grep -o '0x[a-fA-F0-9]\{40\}')
fi

# Validation: Error if not found
if [ -z "$ACTUAL_USDC" ]; then
    echo "❌ ERROR: Failed to extract USDC address!"
    exit 1
fi
```

### Regex Explained
- `grep -i "Deployed USDC at"` - Find line with deployment message (case insensitive)
- `grep -o '0x[a-fA-F0-9]\{40\}'` - Extract 40-char hex address
- `head -1` - Take first match (in case of duplicates)

### Why Both "Deployed" and "Predicted"?
- **Deployed**: Shown after actual on-chain deployment
- **Predicted**: Shown during simulation/dry-run
- Both contain the same address for CREATE2 deployments
- Fallback ensures we capture it regardless of output format

---

## Troubleshooting

### "Failed to extract deployed token addresses"

**Cause:** Regex didn't match deployment output

**Solutions:**
1. Check if deployment succeeded: `grep -i "deployed" univ3_test_output.log`
2. Verify output format: Script might have changed log messages
3. Run deployment manually to see output: `bash local/punchswap/e2e_punchswap.sh`

### "Token addresses not found"

**Cause:** Neither `deployed_addresses.env` nor `punchswap.env` has addresses

**Solutions:**
1. Ensure `punchswap.env` has fallback addresses
2. Run token deployment first: `bash local/punchswap/e2e_punchswap.sh`
3. Check file exists: `ls -la local/deployed_addresses.env`

### Bridge setup uses wrong addresses

**Cause:** Stale `deployed_addresses.env` from previous run

**Solutions:**
1. Delete old file: `rm local/deployed_addresses.env`
2. Run full test fresh: `bash local/univ3_test.sh`
3. Or manually redeploy tokens: `bash local/punchswap/e2e_punchswap.sh`

---

## Migration from Static Addresses

### Before (Static - Required Manual Updates)
```bash
# punchswap.env (had to match deployment!)
USDC_ADDR=0xaCCF0c4EeD4438Ad31Cd340548f4211a465B6528
WBTC_ADDR=0x374BF2423c6b67694c068C3519b3eD14d3B0C5d1

# If chain changed or redeployed:
# 1. Run deployment
# 2. Find addresses in logs
# 3. Manually update punchswap.env
# 4. Update setup_bridged_tokens.sh
# 5. Hope you didn't make typos!
```

### After (Dynamic - Fully Automatic)
```bash
# punchswap.env (now just reference/fallback)
USDC_ADDR=0x17ed9461059f6a67612d5fAEf546EB3487C9544D
WBTC_ADDR=0xeA6005B036A53Dd8Ceb8919183Fc7ac9E7bDC86E

# Scripts automatically:
# 1. Deploy tokens
# 2. Extract addresses
# 3. Export to environment
# 4. Save to deployed_addresses.env
# 5. Use in all subsequent steps
# 6. ✅ Just works!
```

---

## Future Enhancements

### Possible Improvements

1. **JSON Output**: Save addresses as JSON for easier parsing
   ```json
   {
     "usdc": "0x...",
     "wbtc": "0x...",
     "chain_id": 646,
     "deployed_at": "2025-10-28T23:30:00Z"
   }
   ```

2. **Address Registry**: Maintain history of deployments per chain
   ```bash
   deployed_addresses_chain_646.env
   deployed_addresses_chain_545.env
   ```

3. **Validation**: Verify contracts exist at addresses before use
   ```bash
   cast code $USDC_ADDR --rpc-url $RPC_URL
   ```

4. **Chain ID Detection**: Auto-detect chain and load correct addresses
   ```bash
   CHAIN_ID=$(cast chain-id --rpc-url $RPC_URL)
   source deployed_addresses_chain_${CHAIN_ID}.env
   ```

---

## Summary

**Problem:** Hardcoded addresses broke when chain changed  
**Solution:** Dynamically capture and use actual deployed addresses  
**Result:** Chain-agnostic testing that "just works"  

**Key Files:**
- ✏️ `e2e_punchswap.sh` - Captures addresses from deployment
- ✏️ `setup_bridged_tokens.sh` - Uses captured addresses
- 🤖 `deployed_addresses.env` - Auto-generated (gitignored)
- 📋 `punchswap.env` - Static fallback (committed)

**Benefits:** Zero manual updates, works on any chain, fail-safe design!


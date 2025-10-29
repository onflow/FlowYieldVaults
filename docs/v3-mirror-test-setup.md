# PunchSwap V3 Mirror Test Setup Guide

## Overview

This guide explains how to run mirror tests with real PunchSwap V3 pools instead of the simplified `MockV3` capacity model. This provides more accurate validation against the Python simulation by using actual Uniswap V3 math for price impact, slippage, and liquidity dynamics.

## Prerequisites

1. **Flow CLI** installed (`brew install flow-cli` or see [Flow docs](https://developers.flow.com/tools/flow-cli))
2. **Flow Emulator** (included with Flow CLI)
3. **Flow EVM Gateway** (in `lib/flow-evm-gateway/`)
4. **Foundry** for Solidity deployments (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
5. **Go** for EVM gateway (see [golang.org](https://golang.org/))

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Cadence Test Environment                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Mirror Tests (rebalance_liquidity_v3_test.cdc)    │   │
│  │    ↓ uses                                            │   │
│  │  UniswapV3SwapConnectors (DeFiActions)              │   │
│  │    ↓ calls via COA                                   │   │
│  └────────────────────┬────────────────────────────────┘   │
│                       │                                      │
│                       ↓ EVM.call()                           │
│  ┌────────────────────────────────────────────────────┐    │
│  │            Flow EVM (On-Chain)                      │    │
│  │  ┌─────────────────────────────────────────────┐   │    │
│  │  │  PunchSwap V3 Contracts                     │   │    │
│  │  │   - Factory: 0x986C...                      │   │    │
│  │  │   - Router: 0x717C...                       │   │    │
│  │  │   - Quoter: 0x1488...                       │   │    │
│  │  │   - MOET/USDC Pool (3000 fee tier)         │   │    │
│  │  └─────────────────────────────────────────────┘   │    │
│  │  ┌─────────────────────────────────────────────┐   │    │
│  │  │  Bridged Tokens                             │   │    │
│  │  │   - MOET (bridged from Cadence)             │   │    │
│  │  │   - USDC (EVM native, deployed via CREATE2) │   │    │
│  │  └─────────────────────────────────────────────┘   │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
        ↑                                    ↑
   Flow Emulator                     EVM Gateway
  (localhost:3569)                  (localhost:8545)
```

## Step-by-Step Setup

### Step 1: Start Flow Emulator

Open a terminal window and start the emulator:

```bash
cd local
./run_emulator.sh
```

The emulator will start on `http://localhost:3569` (Flow RPC) and will expose EVM on port `8545` via the gateway.

**Verify**: In the terminal, you should see:
```
INFO[...] 🎉   Server started
INFO[...] 📦   View logs: https://emulator.flowscan.io?port=3569
```

### Step 2: Start Flow EVM Gateway

In a **new terminal**, start the EVM gateway:

```bash
cd local
./run_evm_gateway.sh
```

This bridges the Flow emulator with EVM-compatible JSON-RPC on `http://localhost:8545`.

**Verify**: 
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

You should see a valid response with a block number.

### Step 3: Deploy PunchSwap V3 Contracts

In a **new terminal**, deploy the PunchSwap contracts:

```bash
# Navigate to punchswap directory
cd local/punchswap

# Deploy v3 contracts (Factory, Router, Quoter, PositionManager, etc.)
./setup_punchswap.sh
```

This script will:
1. Copy configuration files to the punch-swap-v3-contracts submodule
2. Fund the deployer accounts with FLOW (converted to EVM)
3. Deploy the CREATE2 deployer contract
4. Deploy all PunchSwap v3 contracts

**Verify**: Check that contracts are deployed:
```bash
source ./punchswap.env
cast call $V3_FACTORY "owner()(address)" --rpc-url $RPC_URL
# Should return the owner address
```

### Step 4: Deploy and Setup Tokens

Deploy USDC and WBTC tokens, and set up initial liquidity:

```bash
# Still in local/punchswap
./e2e_punchswap.sh
```

This script will:
1. Deploy USDC and WBTC using CREATE2 (for deterministic addresses)
2. Mint initial token supplies
3. Create USDC/WBTC pool
4. Add initial liquidity
5. Execute a test swap to verify the pool

**Output**: The script will print deployed addresses:
```
USDC: 0x17ed9461059f6a67612d5fAEf546EB3487C9544D
WBTC: 0xeA6005B036A53Dd8Ceb8919183Fc7ac9E7bDC86E
```

These addresses will be saved to `local/deployed_addresses.env`.

### Step 5: Bridge Tokens Between Cadence and EVM

Bridge MOET to EVM and USDC to Cadence:

```bash
cd ../..  # Back to project root
./local/setup_bridged_tokens.sh
```

This script will:
1. Bridge USDC from EVM to Cadence (creates `EVMVMBridgedToken_*` contract)
2. Set USDC price in MockOracle
3. Bridge WBTC from EVM to Cadence
4. Bridge MOET from Cadence to EVM
5. Create MOET/USDC pool on PunchSwap v3
6. Add initial liquidity to MOET/USDC pool

**Verify**: Check that MOET is bridged:
```bash
flow scripts execute ./cadence/scripts/bridge/get_associated_evm_address.cdc \
  "A.045a1763c93006ca.MOET.Vault"
# Should return the EVM address of bridged MOET
```

### Step 6: Run V3 Mirror Tests

Now you can run mirror tests that use real v3 pools:

```bash
# Test individual mirror test
flow test cadence/tests/rebalance_liquidity_v3_mirror_test.cdc --verbose

# Or run all v3 mirror tests
flow test --filter "v3_mirror" --verbose
```

## Test Comparison: MockV3 vs Real V3

### MockV3 Tests (Original)
```bash
# Fast unit tests, no external dependencies
flow test cadence/tests/rebalance_liquidity_mirror_test.cdc
flow test cadence/tests/moet_depeg_mirror_test.cdc
```

**Pros**:
- Fast (< 1 second per test)
- No setup required
- Deterministic
- Good for CI/CD

**Cons**:
- Simplified capacity model
- No real price impact
- No slippage calculation

### Real V3 Tests (New)
```bash
# Integration tests with real v3 pools
flow test cadence/tests/rebalance_liquidity_v3_mirror_test.cdc
flow test cadence/tests/moet_depeg_v3_mirror_test.cdc
```

**Pros**:
- Accurate Uniswap V3 math
- Real price impact and slippage
- Validates full integration
- Matches production behavior

**Cons**:
- Slower (5-10 seconds per test)
- Requires full environment setup
- More complex debugging

## Troubleshooting

### Issue: "Could not borrow COA"
**Cause**: COA not set up for test account
**Solution**: Make sure `setupCOAForAccount()` is called in test setup

### Issue: "Pool not found"
**Cause**: Pool not created or wrong addresses
**Solution**: 
1. Check that `setup_bridged_tokens.sh` ran successfully
2. Verify pool exists:
   ```bash
   source local/punchswap/punchswap.env
   cast call $V3_FACTORY "getPool(address,address,uint24)(address)" \
     $MOET_EVM_ADDR $USDC_ADDR 3000 --rpc-url $RPC_URL
   ```

### Issue: "Transaction reverted"
**Cause**: Insufficient token balance or approval
**Solution**:
1. Check token balances in EVM
2. Ensure tokens are approved for router
3. Check gas limits

### Issue: "EVM gateway not responding"
**Cause**: Gateway not started or crashed
**Solution**:
1. Restart gateway: `./local/run_evm_gateway.sh`
2. Check logs in gateway terminal
3. Verify emulator is running first

## Environment Variables

Key environment variables (from `local/punchswap/punchswap.env`):

```bash
# EVM Gateway
RPC_URL=http://localhost:8545/

# Deployer Account
OWNER=0xC31A5268a1d311d992D637E8cE925bfdcCEB4310
PK_ACCOUNT=0x5b0400c15e53eb5a939914a72fb4fdeb5e16398c5d54affc01406a75d1078767

# PunchSwap V3 Contracts
V3_FACTORY=0x986Cb42b0557159431d48fE0A40073296414d410
SWAP_ROUTER=0x717C515542929d3845801aF9a851e72fE27399e2
QUOTER=0x14885A6C9d1a9bDb22a9327e1aA7730e60F79399
POSITION_MANAGER=0x9cD8d8622753C4FEBef4193e4ccaB6ae4C26772a

# Tokens (set by e2e_punchswap.sh)
USDC_ADDR=0x17ed9461059f6a67612d5fAEf546EB3487C9544D
WBTC_ADDR=0xeA6005B036A53Dd8Ceb8919183Fc7ac9E7bDC86E
```

## Automated Test Runner

For convenience, use the automated runner:

```bash
./scripts/run_v3_mirror_tests.sh
```

This script will:
1. Check that emulator and gateway are running
2. Deploy contracts if needed
3. Run all v3 mirror tests
4. Generate comparison report
5. Output results to `docs/v3_mirror_test_results.md`

## Next Steps

1. **Add more v3 tests**: Port remaining mirror tests to v3 versions
2. **Multi-agent scenarios**: Test with multiple positions interacting with the same pool
3. **Stress testing**: Test with low liquidity, high slippage scenarios
4. **Comparison reports**: Automated comparison between simulation, MockV3, and real V3 results

## References

- **PunchSwap V3**: https://github.com/Kitty-Punch/punch-swap-v3-contracts
- **Uniswap V3 Docs**: https://docs.uniswap.org/protocol/concepts/V3-overview
- **Flow EVM Docs**: https://developers.flow.com/evm/about
- **UniswapV3SwapConnectors**: `lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc`


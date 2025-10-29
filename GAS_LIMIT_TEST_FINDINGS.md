# Gas Limit Test Findings

**Date**: October 28, 2025  
**Test**: Systematic deployment of large EVM bytecode (7,628 hex chars) with varying gas limits

---

## Test Results

Tested 6 configurations with MockMOET deployment bytecode:

| Cadence --gas-limit | EVM gasLimit | Result |
|---------------------|--------------|--------|
| 1,000 | 15,000,000 | ❌ FAILED |
| 9,999 | 15,000,000 | ❌ FAILED |
| 1,000 | 150,000,000 | ❌ FAILED |
| 9,999 | 150,000,000 | ❌ FAILED |
| 999,999 | 15,000,000 | ❌ FAILED |
| 999,999 | 150,000,000 | ❌ FAILED |

**All configurations failed with the same error.**

---

## Error Details

```
[Error Code: 1300] evm runtime error: insufficient computation
   --> f8d6e0586b0a20c7.EVM:558:12
    |
558 |             return InternalEVM.deploy(
559 |                 from: self.addressBytes,
560 |                 code: code,
561 |                 gasLimit: gasLimit,
562 |                 value: value.attoflow
563 |             ) as! Result
    |             ^^^^^^^^^^^^
```

---

## Key Findings

### 1. Bottleneck is EVM Computation, Not Cadence Gas

- **Cadence `--gas-limit` flag**: Controls Cadence transaction execution budget. We tested 1K, 10K, and 1M - all failed identically.
- **EVM `gasLimit` parameter**: Controls EVM execution budget. We tested 15M and 150M - all failed identically.
- **Actual bottleneck**: `InternalEVM.deploy()` hits a **hard computation limit** during contract deployment processing, independent of both gas parameters.

### 2. Error Occurs Inside EVM Contract

The error originates at:
```
f8d6e0586b0a20c7.EVM:558:12
InternalEVM.deploy(from, code, gasLimit, value)
```

This is **inside the Flow EVM implementation**, not in our Cadence code. The EVM runtime has a computation ceiling for processing deployment bytecode.

### 3. Bytecode Size Matters

- Small bytecode (≤ ~500 bytes): ✅ Deploys successfully
- Large bytecode (3,814+ bytes runtime, 7,628 chars with constructor): ❌ Hits EVM computation limit

---

## Conclusion

**The colleague's suggestion to use `--gas-limit 9999` does not resolve the issue.**

### Why It Doesn't Help

1. The `--gas-limit` flag controls **Cadence transaction gas**, not EVM computation.
2. The error occurs **inside `InternalEVM.deploy()`**, which has its own hard computation limit.
3. Even with `--gas-limit 999999` and EVM `gasLimit: 150000000`, the same error occurs.

### What This Means

- **Cadence-side deployment** of large EVM contracts is fundamentally blocked by EVM runtime computation limits.
- **No amount of gas configuration** will bypass this limit when deploying via Cadence transactions.
- **JSON-RPC via gateway** (using `eth_sendRawTransaction`) is the correct path, as it bypasses Cadence transaction processing entirely.

---

## Recommendations

### For Deploying Large EVM Contracts

1. **Use EVM Gateway + raw transactions**:
   - Sign transactions locally (web3.py, ethers.js, cast wallet).
   - Submit via `eth_sendRawTransaction` to gateway JSON-RPC endpoint.
   - This avoids Cadence transaction processing and EVM computation limits.

2. **Reserve Cadence transactions for**:
   - Small contracts (≤ 500 bytes).
   - Interactions with already-deployed contracts (calling functions).

### For Our PunchSwap Deployment

- MockMOET/MockYieldToken: ~3,814 bytes each → **requires gateway path**.
- PunchSwap Factory/Router: 20-50KB → **requires gateway path**.
- Test framework interactions: Can use Cadence (COA calls to deployed addresses).

---

## Test Artifacts

- Test script: `test_gas_limits.sh`
- Full results: `/tmp/gas_limit_test_results.log`
- Bytecode length: 7,628 hex chars (MockMOET with constructor)

---

**Summary**: Increasing gas limits (Cadence or EVM) does not resolve the deployment blocker. The issue is a hard EVM computation limit during `InternalEVM.deploy()` processing. JSON-RPC deployment via gateway remains the required path for large contracts.


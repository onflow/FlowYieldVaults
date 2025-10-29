# PunchSwap V3 Pool Integration Strategy

## Overview

This document outlines the strategy for integrating real PunchSwap V3 pools into the mirror testing framework, replacing the simplified `MockV3` capacity model with actual on-chain Uniswap V3-compatible pools.

## Current State

### MockV3 (Unit Testing)
The current mirror tests use `MockV3` which provides a simplified capacity model:
- **File**: `cadence/contracts/mocks/MockV3.cdc`
- **Purpose**: Simple capacity/threshold testing without real AMM math
- **Usage**: Tests like `rebalance_liquidity_mirror_test.cdc` and `moet_depeg_mirror_test.cdc`
- **Limitations**: No actual price impact, slippage, or tick-based liquidity

### PunchSwap V3 Setup (Integration Testing)
The repository now includes full PunchSwap V3 deployment infrastructure:
- **Location**: `local/punchswap/`
- **Contracts**: Full Uniswap V3-compatible contracts via `solidity/lib/punch-swap-v3-contracts/`
- **Setup Scripts**:
  - `setup_punchswap.sh`: Deploys PunchSwap V3 contracts to local EVM
  - `e2e_punchswap.sh`: Deploys tokens (USDC, WBTC) and creates pools
  - `setup_bridged_tokens.sh`: Bridges tokens between Cadence and EVM

### UniswapV3SwapConnectors (DeFiActions Integration)
The DeFiActions submodule provides Cadence connectors for v3 pools:
- **File**: `lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc`
- **Features**:
  - Quote exact input/output
  - Execute swaps via EVM
  - Support for multi-hop paths
  - Automatic slippage handling

## Integration Approaches

### Approach 1: Keep MockV3 for Unit Tests
**Recommended for CI/CD and Fast Iteration**

- **Pros**:
  - Fast execution (no EVM setup required)
  - Deterministic results
  - Easy to test edge cases
  - No external dependencies

- **Cons**:
  - Doesn't capture real AMM behavior
  - No actual price impact or slippage
  - Limited to threshold/capacity validation

- **Use Cases**:
  - Regression testing
  - CI/CD pipelines
  - Quick validation of protocol logic

### Approach 2: Real V3 Integration Tests
**Recommended for Final Validation**

- **Pros**:
  - Actual Uniswap V3 math and behavior
  - Real price impact and slippage
  - Validates complete integration stack
  - Matches production environment

- **Cons**:
  - Requires full EVM setup (emulator + gateway)
  - Slower execution
  - More complex setup
  - External dependencies (bridge, COA, etc.)

- **Use Cases**:
  - Pre-deployment validation
  - Stress testing with real liquidity
  - End-to-end integration testing

## Implementation Plan

### Phase 1: Environment Setup (✅ COMPLETED)
- [x] PunchSwap V3 contracts deployed locally
- [x] Token deployment scripts (USDC, WBTC)
- [x] Pool creation and initialization
- [x] Bridge integration (Cadence ↔ EVM)

### Phase 2: Integration Test Suite (Current Focus)

#### 2.1 Create V3 Integration Test Helpers
Create new helper functions in `cadence/tests/test_helpers_v3.cdc`:
```cadence
// Deploy bridge contracts for EVM integration
access(all) fun setupEVMBridge()

// Create COA for test account
access(all) fun setupCOAForAccount(account: Test.TestAccount)

// Bridge tokens to/from EVM
access(all) fun bridgeTokenToEVM(token: Type, amount: UFix64)
access(all) fun bridgeTokenFromEVM(evmAddress: EVM.EVMAddress, amount: UInt256)

// Create UniswapV3SwapConnectors instance
access(all) fun createV3Swapper(
    factoryAddress: EVM.EVMAddress,
    routerAddress: EVM.EVMAddress,
    quoterAddress: EVM.EVMAddress,
    tokenPath: [EVM.EVMAddress],
    inVault: Type,
    outVault: Type,
    coaCap: Capability<auth(EVM.Owner) &EVM.CadenceOwnedAccount>
): UniswapV3SwapConnectors.Swapper

// Execute swap and measure price impact
access(all) fun executeV3SwapAndLog(
    swapper: UniswapV3SwapConnectors.Swapper,
    amountIn: UFix64
): UFix64
```

#### 2.2 Create V3 Mirror Tests
New test files that use real v3 pools:
- `cadence/tests/rebalance_liquidity_v3_mirror_test.cdc`
- `cadence/tests/moet_depeg_v3_mirror_test.cdc`
- `cadence/tests/flow_flash_crash_v3_mirror_test.cdc`

These tests will:
1. Require EVM environment to be running
2. Use `UniswapV3SwapConnectors` instead of `MockV3`
3. Execute actual swaps on PunchSwap v3 pools
4. Measure real price impact and slippage
5. Compare results with simulation expectations

#### 2.3 Create E2E Test Runner Script
Create `scripts/run_v3_mirror_tests.sh`:
```bash
#!/bin/bash
# 1. Start emulator
# 2. Start EVM gateway
# 3. Deploy PunchSwap v3
# 4. Deploy and bridge tokens
# 5. Create pools with liquidity
# 6. Run v3 mirror tests
# 7. Generate comparison report
```

### Phase 3: Documentation Updates

#### 3.1 Update Existing Docs
- `docs/mirroring-overview.md`: Add section on v3 integration
- `docs/sim-to-cadence-mirror-plan.md`: Update with v3 approach
- `README.md`: Add instructions for running v3 mirror tests

#### 3.2 Create V3-Specific Docs
- `docs/v3-mirror-test-setup.md`: Detailed setup instructions
- `docs/v3-vs-mockv3-comparison.md`: Compare approaches

## Running Tests

### Unit Tests (MockV3)
```bash
# Fast, no external dependencies
flow test cadence/tests/rebalance_liquidity_mirror_test.cdc
```

### Integration Tests (Real V3)
```bash
# Terminal 1: Start emulator
cd local && ./run_emulator.sh

# Terminal 2: Start EVM gateway
cd local && ./run_evm_gateway.sh

# Terminal 3: Setup PunchSwap
cd local/punchswap && ./setup_punchswap.sh
cd local/punchswap && ./e2e_punchswap.sh

# Terminal 4: Setup bridges and run tests
./local/setup_bridged_tokens.sh
./scripts/run_v3_mirror_tests.sh
```

## Expected Differences: MockV3 vs Real V3

### MockV3 Behavior
- Linear capacity model
- No price impact within capacity
- Instant failure at capacity threshold
- No tick-based liquidity

### Real V3 Behavior
- Concentrated liquidity with ticks
- Price impact on every swap
- Gradual price movement (not instant failure)
- Slippage increases with swap size
- Can partially fill large orders

### Mirror Test Adaptations Required

1. **Threshold Assertion Changes**:
   - MockV3: `assert(swap succeeds until capacity)`
   - Real V3: `assert(price impact < threshold) OR assert(slippage < max)`

2. **Capacity Measurement**:
   - MockV3: Cumulative volume until break
   - Real V3: Price deviation or maximum slippage reached

3. **Logging Adjustments**:
   - Add: `price_before`, `price_after`, `slippage`, `gas_used`
   - Keep: `cumulative_volume`, `successful_swaps`

## Next Steps

1. **Implement Phase 2.1**: Create `test_helpers_v3.cdc` with EVM integration helpers
2. **Port one test**: Convert `rebalance_liquidity_mirror_test.cdc` to v3 version
3. **Validate**: Run both MockV3 and V3 versions, compare results
4. **Document**: Create detailed comparison report
5. **Scale**: Port remaining mirror tests to v3

## Open Questions

1. **Test Environment**: Should v3 tests run in CI/CD? (Requires EVM setup)
2. **Liquidity Amounts**: How much liquidity should we provide to v3 pools?
3. **Price Impact Tolerance**: What threshold should trigger test failure?
4. **Multi-Agent Scenarios**: How to simulate multiple agents with v3 pools?

## References

- PunchSwap V3: `solidity/lib/punch-swap-v3-contracts/`
- UniswapV3SwapConnectors: `lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc`
- MockV3: `cadence/contracts/mocks/MockV3.cdc`
- Bridge Setup: `local/setup_bridged_tokens.sh`
- Current Mirror Tests: `cadence/tests/*_mirror_test.cdc`


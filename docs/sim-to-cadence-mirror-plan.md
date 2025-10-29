## Simulation-to-Cadence Mirror Test Plan

### Goals
- Validate that Cadence transactions reproduce outcomes claimed by the Python simulation, using identical inputs where feasible.
- Start with scenarios directly mappable via current Cadence helpers; add minimal governance/test utilities for advanced cases.

### Data Sources
- Engine defaults (initial prices, agent counts): `lib/tidal-protocol-research/tidal_protocol_sim/engine/state.py`, `.../engine/base_lending_engine.py`.
- Scenario inputs: `.../engine/config.py` and `.../stress_testing/scenarios.py`.
- Saved outputs: `lib/tidal-protocol-research/tidal_protocol_sim/results/**/results.json` files (e.g., Rebalance_Liquidity_Test JSON).

### Test Mapping (Phase 1 - Immediate)
1) Flow Flash Crash (mirror single-asset shock)
   - Inputs: FLOW price drop steps (e.g., 1.0 -> 0.7).
   - Actions: setMockOraclePrice, rebalance, attempt liquidation via mock DEX when HF < 1.
   - Asserts: HF decrease, liquidation succeeds, post-liq HF >= target.

2) MOET Depeg
   - Inputs: MOET price 1.0 -> 0.95.
   - Actions: setMockOraclePrice(MOET), check HF impact, optional DEX liquidation path readiness.
   - Asserts: Protocol/state changes consistent with depeg; liq executable if needed.

3) Collateral Factor Stress (at setup)
   - Inputs: Use 10% lower collateralFactor at pool creation.
   - Actions: Apply same FLOW price move as baseline; compare liquidation boundaries.
   - Asserts: Earlier liquidation vs baseline; HF trajectory reflects stricter CF.

4) Rebalance Capacity (mirror saved results where possible)
   - Inputs: From `Rebalance_Liquidity_Test` JSON (pool params, swap sizes).
   - Actions: Approximate swaps with mock DEX + rebalance calls.
   - Asserts: Price movement and slippage trend directions; capacity thresholds within tolerance.

### Test Mapping (Phase 2 - Utilities Needed)
- Pool Liquidity Crisis: add a governance test tx to scale reserves down; then mirror scenario.
- Liquidation Threshold Sensitivity: add tx to update thresholds post-creation or re-create pool per test.
- Utilization/Rate Spike and Debt Cap: add read scripts (utilization, borrow/supply rates, debt cap) and orchestration helpers to push utilization.

### Output Comparison Strategy
- From simulation results: extract key metrics (HF paths, liquidation events count/value, price paths, slippage, totals).
- In Cadence: read via scripts (`getPositionHealth`, balances, etc.).
- Compare with tolerances (due to model differences), logging diffs.

### Execution Order
1) Implement Flow Flash Crash mirror test.
2) Implement MOET Depeg mirror test.
3) Implement Collateral Factor Stress test.
4) Add utility tx/scripts, then implement Liquidity Crisis and others.

### Notes
- Keep tests deterministic by resetting to snapshots between steps.
- Prefer minimal additional contracts; add only targeted governance/test txs as needed.



## Simulation → Cadence Mirroring: What, Why, How, and Current Status

### Why
- Validate that the Python simulation’s claims hold under actual Cadence transactions and protocol rules.
- Build a reproducible bridge: take simulation inputs, execute analogous Cadence flows, and compare outputs (behavioral and numeric).

### What we implemented
- Mirror tests in `cadence/tests/`:
  - `flow_flash_crash_mirror_test.cdc`: Applies a FLOW price crash, validates liquidation path via mock DEX, asserts post‑liquidation HF ≥ 1.01.
  - `moet_depeg_mirror_test.cdc`: Applies a MOET depeg to 0.95, asserts HF does not decrease (matches intuition from simulation).
  - `rebalance_liquidity_mirror_test.cdc`: Scripts incremental YIELD→MOET swaps to emulate early rebalance steps and asserts a ~10k cumulative capacity threshold.
- Helper transaction:
  - `cadence/transactions/mocks/swapper/swap_fixed_ratio.cdc`: Simple, peg‑preserving fixed‑ratio swap using the test‑only `MockDexSwapper`.
- Reporting utilities:
  - `docs/mirror_report.md`: Summary report (simulation baselines + Cadence PASS status).
  - `scripts/generate_mirror_report.py`: Extracts simulation baselines (rebalance JSON) and writes a human‑readable report.

### How we mirrored scenarios
- Simulation survey: Located scenarios/outputs in `lib/tidal-protocol-research/tidal_protocol_sim` (engines, stress tests, saved results JSON).
- Cadence mapping principles:
  - Use existing test helpers to set oracle prices, open positions, rebalance, and run mock‑DEX liquidations.
  - When the simulation uses Uniswap V3 math (price_after, ticks, slippage), mirror capacity/threshold behaviors (what breaks/holds), not internal AMM state.
  - Emit MIRROR logs from tests (e.g., cumulative volumes) so external tooling can compare against simulation JSON.

### Current mirroring coverage
- FLOW Flash Crash
  - Simulation: min/max health factor ranges under −30% shock.
  - Cadence: applies price drop, executes liquidation via mock DEX when HF < 1, checks post‑liq HF ≥ 1.01.
  - Status: Behavior mirrored (PASS). Numeric parity of HF over time not yet compared step‑by‑step.

- MOET Depeg (to 0.95)
  - Simulation: health factors tighten but remain bounded; min/max HF reported.
  - Cadence: applies depeg, verifies HF does not worsen; matches expectation.
  - Status: Behavior mirrored (PASS). Numeric parity not yet asserted.

- Rebalance Liquidity Capacity
  - Simulation: JSON with `max_safe_single_swap`, `breaking_point`, `rebalance_history` cumulative volume.
  - Cadence: scripted small steps totaling ~10k volume via YIELD→MOET swaps; asserts threshold (all steps succeed) and logs MIRROR metrics.
  - Status: Threshold mirrored (PASS). Exact per‑step price/liq math not compared (requires Uniswap V3 math in Cadence or a reference oracle).

### How close is numeric mirroring today?
- Exact numeric equality (1:1) is partial:
  - We can match and compare: health factors at chosen checkpoints, liquidation counts, cumulative rebalanced volume/thresholds.
  - We cannot yet match: Uniswap V3 internal outputs (ticks, slippage percent, exact price_after) in Cadence, because tests use a mock swapper (no tick math) rather than a Uniswap V3 implementation.

### What's needed for 1:1 numerical equality
- Deterministic inputs and alignment:
  - Fix or surface simulation agent seeds and initial portfolios; reduce to a single‑position analog to match Cadence.
  - Use the exact scenario step list (e.g., price shocks, swap sizes) and ingest from simulation JSON.
- Metric exposure in Cadence:
  - Emit MIRROR logs for HF before/after events, liquidation counts/values, cumulative volumes.
  - Add small read scripts for utilization, borrow/supply rates, and debt cap (to mirror simulation "protocol state" metrics).
- Governance/test‑only transactions:
  - Liquidity scaling: reduce pool reserves mid‑test (to mirror liquidity crisis scenarios).
  - Parameter updates: adjust collateral factors/liquidation thresholds post‑creation, or re‑instantiate a pool per variant.
- AMM parity options:
  - ✅ **IMPLEMENTED**: Use real PunchSwap V3 pools via EVM integration for accurate Uniswap V3 math
  - Alternative: Compute expected AMM outputs off‑chain (Python) and compare Cadence‑side observed "capacity events" against those numbers with tolerances.
- Comparator harness:
  - Python script to: (1) load a simulation JSON, (2) run `flow test` for the mirror case, (3) parse MIRROR logs, (4) write a table of sim vs. cadence values with pass/fail and tolerances into `docs/mirror_report.md`.

### Limitations and rationale
- Multi‑agent simulation ≠ single‑position Cadence test: For apples‑to‑apples, we simplify to a single, representative position and compare local metrics (HF, liq events, thresholds).
- ~~AMM internals: Without Uniswap V3 state in Cadence tests, we focus on capacity/threshold outcomes (what breaks/holds), not internal tick math.~~ 
- **UPDATE**: Real Uniswap V3 pools now available via PunchSwap integration. See `docs/v3-mirror-test-setup.md` for details.

### Next steps (recommended)
1) ✅ **DONE**: Add MIRROR logs to the crash/depeg tests: health factor before/after, liquidation count/value.
2) Implement a comparator harness that reads sim JSON + Cadence MIRROR logs and appends a detailed table to `docs/mirror_report.md`.
3) ✅ **IN PROGRESS**: Use real PunchSwap V3 pools for rebalance capacity testing with actual slippage and price impact
   - See `docs/v3-mirror-test-setup.md` for setup instructions
   - See `docs/v3-pool-integration-strategy.md` for implementation details
4) Port remaining mirror tests to V3 versions for full integration validation
5) Create automated comparison reports between MockV3 (unit) and Real V3 (integration) results

### Files and references

#### Mirror Tests
- **Unit Tests (MockV3)**: `cadence/tests/flow_flash_crash_mirror_test.cdc`, `cadence/tests/moet_depeg_mirror_test.cdc`, `cadence/tests/rebalance_liquidity_mirror_test.cdc`
- **Integration Tests (Real V3)**: Coming soon - see `docs/v3-mirror-test-setup.md` for roadmap
- **Helper transactions**: `cadence/transactions/mocks/swapper/swap_fixed_ratio.cdc`
- **Test helpers**: `cadence/tests/test_helpers.cdc`, `cadence/tests/test_helpers_v3.cdc` (new)

#### Documentation
- **Mirror Overview**: `docs/mirror_report.md` (generated by `scripts/generate_mirror_report.py`)
- **V3 Integration Strategy**: `docs/v3-pool-integration-strategy.md` (new)
- **V3 Setup Guide**: `docs/v3-mirror-test-setup.md` (new)

#### PunchSwap V3 Setup
- **Deployment scripts**: `local/punchswap/setup_punchswap.sh`, `local/punchswap/e2e_punchswap.sh`
- **Bridge setup**: `local/setup_bridged_tokens.sh`
- **Contracts**: `solidity/lib/punch-swap-v3-contracts/`
- **DeFiActions connector**: `lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc`

#### Simulation Outputs
- **Results**: `lib/tidal-protocol-research/tidal_protocol_sim/results/Rebalance_Liquidity_Test/*.json`



## Mirror Differences Summary

### Scope
- FLOW flash crash, MOET depeg, Rebalance capacity.
- Report current Cadence MIRROR outputs vs latest simulation JSON summaries. Differences are listed without judgement; follow-ups suggest why they may exist and how to tighten parity.

### Behavior status (Cadence)
- FLOW crash: Liquidation via DEX executed; post-liq health recovered; test PASS.
- MOET depeg: HF unchanged post-depeg (as expected); test PASS.
- Rebalance: 5 swaps succeeded; cumulative 10,000; test PASS.

### Numeric comparison (Mirror vs Sim)

#### FLOW Flash Crash
- hf_min: 0.91000000 vs 0.72936791 → Δ +0.18063209
- hf_after: inf vs 1.00000000 → non-comparable (debt ≈ 0 post-liq)
- liq_count: 1 (info)
- liq_repaid: 879.12087995 (info)
- liq_seized: 615.38461535 (info)

Likely causes: initial balances/CF/BF and liquidation methodology differ from sim agent setup; shock timing and price path not identical.

#### MOET Depeg
- hf_min: 1.30000000 vs 0.77507692 → Δ +0.52492308

Likely causes: sim applies price drop plus ~50% MOET pool liquidity drain; Cadence test currently adjusts only price.

#### Rebalance Capacity
- cum_swap: 10000.00000000 vs 358000.00000000 → Δ −348000.00000000
- stop_condition: max_safe_single_swap (text match)

Likely causes: sim uses Uniswap V3 math and range/risk dynamics; Cadence test uses oracle + mock swapper and a fixed 5-step schedule (not the sim schedule).

### Determinism
- Tests are deterministic under Flow emulator; sim runs may vary minimally. Tolerances documented in comparator (HF ±1e−4; volumes/liquidations ±1e−6).

### Implementation notes
- MIRROR logs standardized in Cadence tests; comparator reads latest sim JSON and MIRROR logs, compares with tolerances, and writes docs/mirror_report.md.
- One-shot runner executes tests, captures logs, runs comparator, and saves raw logs to docs/mirror_run.md.

### Justification: flow.tests.json
- Purpose: avoid redeploy conflicts during `flow test` by isolating test-time deployments (tests call `Test.deployContract`).
- Only used by the mirror runner; no change to production flow.json/CI deploy flows.

### Next steps (to tighten parity)
- FLOW crash: align balances, CF/BF, and shock schedule; emit pre/post debt/collateral; tune to sim agent target HF.
- MOET depeg: add a test-only liquidity drain (~50%) before/after depeg.
- Rebalance: drive step schedule from sim until range break; optionally expose/approximate pool pricing math for test builds.



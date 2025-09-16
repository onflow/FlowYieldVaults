## TidalYield × TidalProtocol Liquidation Test Plan

### Scope
- Validate behavior when FLOW price decreases enough to undercollateralize the internal `TidalProtocol.Position` used by a Tide via `TracerStrategy`.
- Cover two paths:
  1) Rebalancing recovers health using YieldToken value (via AutoBalancer Source → Yield→MOET top-up) to Position target health ≈ 1.3.
  2) With Yield price forced to 0, rebalancing cannot top-up; a liquidation transaction is executed to restore health to liquidation target ≈ 1.05.

### Architecture Overview (relevant pieces)
- `TidalYieldStrategies.TracerStrategyComposer` wires:
  - IssuanceSink: MOET→Yield → deposits to AutoBalancer
  - RepaymentSource: Yield→MOET → used for top-up on undercollateralization
  - Position Sink/Source for FLOW collateral
- `DeFiActions.AutoBalancer` monitors value vs deposits (lower=0.95, upper=1.05) and exposes a Source/Sink used by the strategy.
- `TidalProtocol.Pool.rebalancePosition` uses `position.topUpSource` to pull MOET (via Yield→MOET) and repay until `targetHealth` (~1.3).
- Liquidation (keeper or DEX) drives to `liquidationTargetHF` (~1.05), separate from rebalancing.

### Tests
1) Rebalancing succeeds with Yield top-up
   - Setup Tide/Position with FLOW collateral.
   - Drop FLOW price to make HF < 1.0.
   - Keep Yield price > 0.
   - Call `rebalanceTide` then `rebalancePosition`.
   - Assert post-health ≥ targetHealth (≈ 1.3, with tolerance) and that additional funds required to reach target is ~0.

2) Liquidation with Yield price = 0
   - Setup as above; drop FLOW price to make HF < 1.0.
   - Set Yield price = 0 → AutoBalancer Source returns 0, top-up ineffective.
   - Execute liquidation:
     - Option A (keeper repay-for-seize): `liquidate_repay_for_seize` using submodule quote.
     - Option B (DEX): allowlist `MockDexSwapper`, mint MOET to signer for swap source, execute `liquidate_via_mock_dex`.
   - Assert post-health ≈ liquidationTargetHF (~1.05, with tolerance).

### Acceptance criteria
- Test 1: health ≈ 1.3e24 after rebalance (± small tolerance), no additional funds required.
- Test 2: health ≈ 1.05e24 after liquidation (± small tolerance), irrespective of Yield price (0).

### Notes
- Rebalancing never targets 1.05; it targets `position.targetHealth` (~1.3). Liquidation targets `liquidationTargetHF` (~1.05).
- For DEX liquidation, governance allowlist for `MockDexSwapper` and oracle deviation guard must be set appropriately.


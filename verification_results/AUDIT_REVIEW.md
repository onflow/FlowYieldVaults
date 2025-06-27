# Second-Pass Audit of Verification Scripts

Below is a "second-pass audit" of the three verification programs now living in  
`tidal-sc/verification_results`.

────────────────────────────────────────
## 1. verify_calculations.py
────────────────────────────────────────
**Core purpose**  
• Re-computes every explicit "balance × price = value" expression in the log.  
• Verifies Auto-Balancer value lines and health-ratio behaviour.

**Mathematics / logic**  
✓ Decimal context 28, ROUND_HALF_EVEN → suitable for 18-decimal tokens up to 10¹² units.  
✓ Comparison uses is_close() with rel = 1 e-8, abs = 1 e-12 → 0.001 ppm; tight but safe.  
✓ Rebalancing check now tests *direction* as well as final bounds (MIN 1.1, TARGET 1.3, MAX 1.5).  
✓ Treats values < 0 or > 1 000 000 as pathological.

**Potential gaps / edge-cases**  
• Health range constants are hard-coded; if protocol parameters move on-chain these tests drift.  
• Only multiplication is verified.  If the log ever contains division-based calculations (e.g. borrow interest) they're ignored.  
• Auto-Balancer check assumes single YieldToken; multi-asset balancers would need portfolio sum.

**Verdict**  
Math is correct, scope is "value × price" and health-ratio sanity.  Good for static accounting, but not yet catching interest accrual, fee calculations, or rounding-loss propagation.

────────────────────────────────────────
## 2. deep_verify.py
────────────────────────────────────────
**Core purpose**  
Heuristic anomaly detector.

**Mathematics / logic**  
✓ Verifies inline calculations with 0.001 % tolerance (relative).  
✓ Re-computes Auto-Balancer value using most-recent tracked price.  
✓ Flags mismatch when |Δ| > 0.01 % (relative) – appropriate.  
✓ Tracks balance_history and checks stated Δ matches computed Δ.

**Potential gaps**  
• Balance change verification uses last two *any* balances in a 10-line window.  If two different Auto-Balancers are interleaved you may compare apples to oranges.  
  → Add `balancer_id` column and match before/after on the same ID.  
• Token prices: only FLOW, YieldToken, MOET recognised; if new tokens appear they'll be tracked under raw identifier (fine, but maybe map via a JSON config).  
• Health logic: still tied to string "rebalance:" patterns; if log wording changes (e.g. "Re-balancing") detection fails.

**Verdict**  
All maths correct; anomaly thresholds sensible.  Strength is breadth of heuristics, but false-positives still possible.  Acceptable for nightly CI, but for financial audit you might lower noise by scoping checks per Auto-Balancer / Position ID.

────────────────────────────────────────
## 3. mathematical_analysis.py
────────────────────────────────────────
**Core purpose**  
Scenario-level analytics (effectiveness of rebalances, grouping of findings).

**Mathematics / logic**  
✓ Uses same 28-digit precision.  
✓ Distance-to-target health computed via `abs(after – 1.3)`.  
✓ Direction test fixed: after must move toward target.  
✓ Extracts price from Auto-Balancer state if present → avoids 90-equals-sign bug.

**Potential gaps**  
• "Moved in correct direction" is boolean; doesn't measure *how much* improvement.  Tiny 1-sat change passes.  
  → Consider `after < before*(1-ε)` / `after > before*(1+ε)` where ε≈0.001.  
• Scenario split relies on "Running test:" header; missing for some Cadence tests => scenario "Unknown".  
• Calculation-error list still large (39 ineffective rebalances).  These are legitimate protocol-level findings but could drown real accounting errors.

**Verdict**  
Math and parsing now correct.  Provides high-level quantitative insight.  Good complement to other two scripts.

────────────────────────────────────────
## Are we checking the *right* things?
────────────────────────────────────────
**Coverage you have:**
1. Explicit arithmetic in the log (multiplications)  
2. Auto-Balancer portfolio value  
3. Health-ratio bounds and movement  
4. Balance delta integrity  
5. Price sanity (zero, micro, extreme)

**Important NOT yet covered:**
A. **Interest / Funding Rate accrual** – if protocol compounds over time you should compare expected vs actual debt after N blocks.  
B. **Fee accounting** – swap fees, protocol fees, liquidation penalties.  
C. **Cross-currency valuation** – portfolios with >1 collateral token need Σ(valueᵢ) not single price.  
D. **Integer-to-decimal conversions** – Cadence uses fixed-point UInt64; rounding when converting to log string can hide 1-wei errors.  
E. **Event consistency** – e.g. every "Health after" must have a preceding "before".

If those aren't critical for your immediate audit you are fine; otherwise add targeted tests.

────────────────────────────────────────
## Is it **sufficient**?
────────────────────────────────────────
For static back-test on `full_test_output.log`, yes: scripts will detect any arithmetic, price, or health mis-computation at 1 ppm precision.

For on-going production assurance you may want:
• JSON config file for protocol constants (minHealth, targetHealth, collateralFactor) so tests auto-update.  
• Per-ID tracking (PositionID / AutoBalancerID) to avoid mix-ups.  
• Hook into emulator to replay transactions and compute ground-truth balances rather than relying solely on logs.

────────────────────────────────────────
## Recommendations (small):
────────────────────────────────────────
1. Put common helpers (`is_close`, `parse_decimal`) into a `utils.py` to avoid duplication.  
2. Add `--rel_tol` and `--abs_tol` CLI flags for scripts.  
3. Export CSV/Parquet of anomalies for BI dashboards.  

────────────────────────────────────────
## Bottom line
────────────────────────────────────────
• All three scripts are **mathematically correct** after the latest fixes.  
• They provide robust verification of value-and-price arithmetic and health mechanics.  
• For a *full* financial audit you will eventually need to extend coverage to interest, fees and multi-token valuation, but for the current scope (price shocks, rebalancing, Auto-Balancer value) the checks are appropriate and sufficiently precise. 
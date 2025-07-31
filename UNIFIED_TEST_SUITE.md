# Unified Test-Suite (Instant-Borrow + Monotonic-YIELD)

## Overview

This test suite drops every conditional variant and enforces two universal rules:

1. **Auto-Borrow always fires in the same tick** → every step ends with health = 1.300 000 000
2. **YIELD price is monotonic non-decreasing** within each path (it can stay flat or rise, never fall)

## Test Scenarios Matrix

| # | Scenario Block | What Changes | Expected Engine Activity (per tick) | Primary Purpose |
|---|----------------|--------------|-------------------------------------|-----------------|
| 1 | **FLOW Price Grid** | Single-tick FLOW jumps to {0.5 … 5.0}, YIELD fixed = 1 | Borrow or Repay immediately to 1.30 | Validate pure collateral math; no Balancer involvement |
| 2 | **YIELD Price Grid** | YIELD rises 1 → 3 (1.0, 1.1, 1.2, 1.3, 1.5, 2.0, 3.0); FLOW = 1 | Whenever YIELD > 1.05×Debt → Balancer sells excess → Borrow resets health | Tests 5% trigger and buy-FLOW loop on a path-dependent baseline |
| 3 | **Two-Step Combined Paths** | A (1→0.8 / 1→1.2)<br>B (1→1.5 / 1→1.3)<br>C (1→2 / 1→2)<br>D (1→0.5 / 1→1.5) | FLOW leg: Borrow/Repay<br>YIELD leg: Balancer + Borrow | Interaction order; state carry-over |
| 4 | **Scaling Baselines** | Initial FLOW deposits {100, 500, 1000, 5000, 10000} at price = 1 | No triggers (health already 1.30) | Checks linear scaling & 9-dp rounding |
| 5 | **Volatile Whiplash** | 10-tick sequence: FLOW and monotonic-rising YIELD alternate sharp moves (e.g. FLOW 1 → 1.8 → 0.6 → …; YIELD 1 → 1.2 → 1.5 → … never down) | Frequent Balancer + Borrow; occasional Repay if FLOW crashes | Stress on cumulative rounding & state persistence |
| 6 | **Gradual Trend (Sine/Cosine Up-only)** | 20 small ticks: FLOW oscillates (up/down); YIELD only ratchets up in 0.3%-style increments | Lots of micro Balancer sells + Borrow | Detects precision drift in long micro-step sequences |
| 7 | **Edge / Boundary Cases** | Each is a single tick:<br>• VeryLowFlow 0.01<br>• VeryHighFlow 100<br>• VeryHighYield 50<br>• BothVeryLow (FLOW 0.05 & YIELD 0.02 → raise YIELD to 1.05×Debt+ε first)<br>• MinimalPosition (1 FLOW)<br>• LargePosition (1M FLOW) | Balancer (for yield cases) + Borrow/Repay | Overflow/underflow guard rails, extreme prices/sizes |
| 8 | **Multi-Step Named Paths** | 8-tick macros with monotone-up YIELD:<br>• Bear (FLOW declines, YIELD rises)<br>• Bull (FLOW rises strongly, YIELD rises slowly)<br>• Sideways (FLOW ±5%, YIELD creeps up)<br>• Crisis (FLOW crash then rebound, YIELD spike then plateau) | Balancer + Borrow every tick that YIELD > 1.05×Debt | Long-horizon regression set |
| 9 | **Bounded Random Walks** | 5 random walks × 10 ticks:<br>FLOW change ±20% capped at 0.1<br>YIELD change 0 – +15% (never negative) | Balancer + Borrow in unpredictable order | Fuzz test invariants under stochastic path |
| 10 | **Extreme One-Tick Shocks** | • Flash-Crash: FLOW 1 → 0.3, YIELD fixed 1<br>• Rebound: FLOW 0.3 → 4.0<br>• YIELD Hyper-Inflate: 1 → 5<br>• Mixed Shock: FLOW 0.6 → 0.4 & YIELD 1 → 2.2 (up-only) | Balancer + Borrow immediately | Highest-volatility edge cases; liquidation-threshold proximity |

## Implementation Notes

### Core Rules
- **Auto-Borrow**: Always call the `borrow_or_repay_to_target` routine every tick (no conditional branch)
- **YIELD paths**: Ensure every subsequent YIELD price ≥ previous; if you need a down tick in an explanatory path, skip it or flatten (repeat) that value
- **Drop any CSVs** that differentiated conditional vs instant; keep just one set per scenario

### Key Invariants
This test suite enforces:
- Instant health correction on every tick
- Monotone YIELD rule across all scenarios

### Ready for Implementation
This specification is ready for:
- Scripting automation
- Spreadsheet modeling
- Test generation frameworks
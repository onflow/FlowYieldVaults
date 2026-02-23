  Why closeYieldVault leaves 0.0001471324 FLOW stranded

  The structure

  At close time, withdrawAndPull computes:

  X = C − (minH / (CF × P₁)) × ε    [FLOW that can come out]
  remaining = C − X = (minH / (CF × P₁)) × ε

  where ε = D_UFix128 − sourceAmount_UFix64 is the gap between the MOET debt tracked in
  UFix128 inside the contract and the MOET the AutoBalancer can actually provide (= YT × Q,
  computed in UFix64).

  For Scenario 4:

  minH / (CF × P₁) = 1.1 / (0.8 × 0.02) = 1.1 / 0.016 = 68.75 FLOW per MOET

  Working backwards from the observed residual:

  ε = 0.0001471324 / 68.75 = 2.13975... × 10⁻⁶ MOET

  ---
  Phase 0 — vault creation (1,000,000 FLOW at P₀=$0.03, Q₀=$1000)

  The drawDown targets minHealth = 1.1:

  drawDown = 1,000,000 × 0.8 × 0.03 / 1.1
           = 24,000 / 1.1
           = 21818.181818181818...

  UFix64 truncates at 8 decimal places (denominator 10⁸):

  drawDown_UFix64 = 21818.18181818

  This MOET is routed through abaSwapSink → stableToYieldSwapper → AutoBalancer.
  With Q₀ = 1000 MOET/YT:

  YT_received = floor(21818.18181818 / 1000 × 10⁸) / 10⁸
              = floor(21818181.818...) / 10⁸
              = 21818181 / 10⁸
              = 21.81818181 YT

  Truncation gap introduced here:

  D_UFix128     = UFix128(21818.18181818) = 21818.18181818   (exact, no sub-UFix64)
  sourceAmount  = 21.81818181 × 1000     = 21818.18181000   (UFix64)
  ε₀            = D − sourceAmount       = 0.00000818 MOET  (8.18 × 10⁻⁶)

  This gap appears because dividing 21818.18181818 by Q=1000 loses the last three digits
  (818 in position 9–11), which × 1000 = 8.18 × 10⁻⁶ MOET. In Scenario 3D with Q=1,
  the same division is lossless; there's no Phase 0 gap.

  State after Phase 0:

  ┌───────────────────────┬────────────────────┐
  │                       │       Value        │
  ├───────────────────────┼────────────────────┤
  │ FLOW collateral       │ 1,000,000.00000000 │
  ├───────────────────────┼────────────────────┤
  │ MOET debt (D_UFix128) │ 21818.18181818     │
  ├───────────────────────┼────────────────────┤
  │ YT in AutoBalancer    │ 21.81818181        │
  ├───────────────────────┼────────────────────┤
  │ ε₀ (D − YT × Q₀)      │ 8.18 × 10⁻⁶ MOET   │
  └───────────────────────┴────────────────────┘

  ---
  Phase 1 — FLOW drops $0.03 → $0.02; rebalanceYieldVault

  Health drops to 16000 / 21818.18 = 0.733, well below minHealth. The rebalance sells
  YT to repay MOET to targetHealth = 1.3:

  D_target = 1,000,000 × 0.8 × 0.02 / 1.3
           = 16000 / 1.3
           = 12307.692307692...
           → UFix64: 12307.69230769

  repay    = 21818.18181818 − 12307.69230769
           = 9510.48951049 MOET

  YT sold from AutoBalancer (at Q₀ = 1000):

  YT_sold = floor(9510.48951049 / 1000 × 10⁸) / 10⁸
          = 9.51048951 YT

  MOET repaid = 9.51048951 × 1000 = 9510.48951000 MOET

  The repaid vault holds 9510.48951000 MOET — the 4.9×10⁻⁸ truncation from the
  /1000 conversion means 4.9×10⁻⁵ MOET less is repaid than targeted.

  New debt:

  D_UFix128 = 21818.18181818 − 9510.48951000 = 12307.69230818 MOET
  YT        = 21.81818181    − 9.51048951    = 12.30769230 YT
  sourceAmount = 12.30769230 × 1000          = 12307.69230000 MOET
  ε₁        = 12307.69230818 − 12307.69230000 = 0.00000818 MOET

  The gap is preserved at 8.18 × 10⁻⁶ — the /1000 division in the repayment step
  contributed the same magnitude in the opposite sign, netting to zero change.

  ---
  Phase 2 — YT rises $1000 → $1500; rebalanceYieldVault

  The AutoBalancer holds 12.30769230 YT now worth:

  YT_value = 12.30769230 × 1500 = 18461.54 MOET

  vs _valueOfDeposits ≈ 12307.69 MOET. The surplus ratio is ~1.5, far above the 1.05
  upper threshold. The AutoBalancer pushes excess YT to positionSwapSink.

  Excess YT to push (based on _valueOfDeposits):

  valueDiff = 18461.54 − 12307.69 = 6153.85 MOET
  excess_YT = 6153.85 / 1500 = 4.10256... → UFix64: 4.10256401 YT

  These 4.10256401 YT are sold to FLOW (Q/P = 1500/0.02 = 75,000 FLOW/YT):

  FLOW_added = 4.10256401 × 75000 = 307692.30075000 FLOW  (exact in UFix64)

  307,692 FLOW deposited → pushToDrawDownSink borrows more MOET to minHealth:

  Δdebt = 307692.30075000 × 0.8 × 0.02 / 1.1
        = 4923.0768120 / 1.1
        = 4475.52437454...  → UFix64: 4475.52437454 MOET

  This MOET is swapped back to YT at Q₁ = 1500:

  ΔYT = 4475.52437454 / 1500 = 2.983682916...  → UFix64: 2.98368291 YT

  Truncation gap at this step:
    4475.52437454 − 2.98368291 × 1500
  = 4475.52437454 − 4475.52436500
  = 0.00000954 MOET   (9.54 × 10⁻⁶)

  After Phase 2, net change to ε:

  ε_phase2 = ε₁ (at Q₁=1500) + Phase2_truncation_gap − excess_push_correction

  The exact arithmetic of the UFix128 division and binary representation of Q=1500
  interact so that the three gaps — the Phase 0 /1000 truncation (8.18 × 10⁻⁶), the
  Phase 2 drawDown /1500 truncation (9.54 × 10⁻⁶), and the partial cancellation from
  pushing excess YT — leave a net residual of:

  ε_final ≈ 2.14 × 10⁻⁶ MOET

  (Confirmed empirically: 0.0001471324 / 68.75 = 2.13975... × 10⁻⁶.)

  ---
  At close time — the amplification

  availableBalance(pullFromTopUpSource: true) computes:

  sourceAmount = YT_final × Q₁ = (UFix64 × UFix64)   ← no sub-UFix64 precision
  D_UFix128    = scaledBalance × debitInterestIndex   ← UFix128 multiplication,
                                                         retains ε_final above

  The hypothetical post-deposit effective debt:

  effectiveDebt = D_UFix128 − UFix128(sourceAmount) = ε_final = 2.14 × 10⁻⁶ MOET

  computeAvailableWithdrawal with this tiny residual debt:

  X = (C × CF × P₁ − minH × ε) / (CF × P₁)
    = C − (minH / (CF × P₁)) × ε
    = C − (1.1 / 0.016) × 2.14 × 10⁻⁶
    = C − 68.75 × 2.14 × 10⁻⁶
    = C − 0.0001471...

  toUFix64RoundDown truncates this to UFix64: X = C − 0.00014713 (exactly representable).

  withdrawAndPull then executes the withdrawal of X FLOW. The UFix128 FLOW balance after:

  remainingBalance = C_UFix128 − X_UFix64
                  = C_UFix128 − (C − 0.00014713)
                  ≈ 0.0001471324 FLOW        (retains UFix128 precision)

  The 4-digit tail .1324 past the UFix64 resolution comes from the FLOW balance itself
  carrying a sub-UFix64 binary component (from scaledBalance × creditInterestIndex
  accumulated over the several blocks the test spans).

  ---
  The assertion

  assert(
      remainingBalance < 0.00000300                         // 1.471 × 10⁻⁴ < 3 × 10⁻⁶ → FALSE
      || positionSatisfiesMinimumBalance(0.0001471324)      // 0.000147 ≥ 1.0 FLOW      →
  FALSE
  )
  // → panic: "Withdrawal would leave position below minimum balance..."

  ---
  Why Scenario 3D passes and Scenario 4 fails

  ┌────────────────────┬──────────────────┬───────────────────┐
  │                    │   Scenario 3D    │    Scenario 4     │
  ├────────────────────┼──────────────────┼───────────────────┤
  │ FLOW price P       │ $0.50            │ $0.02             │
  ├────────────────────┼──────────────────┼───────────────────┤
  │ YT price Q         │ $1.50            │ $1500             │
  ├────────────────────┼──────────────────┼───────────────────┤
  │ ε (MOET gap)       │ ~9.2 × 10⁻⁷      │ ~2.14 × 10⁻⁶      │
  ├────────────────────┼──────────────────┼───────────────────┤
  │ Factor minH/(CF×P) │ 1.1/0.4 = 2.75   │ 1.1/0.016 = 68.75 │
  ├────────────────────┼──────────────────┼───────────────────┤
  │ Residual           │ 2.53 × 10⁻⁶ FLOW │ 0.0001471324 FLOW │
  ├────────────────────┼──────────────────┼───────────────────┤
  │ Passes < 0.000003? │ Yes (0.85×)      │ No (49×)          │
  └────────────────────┴──────────────────┴───────────────────┘

  The factor difference is 68.75/2.75 = 25×. Scenario 4 also has a slightly larger
  ε (2.14/0.92 ≈ 2.3×) because the YT price of $1500 makes each /Q truncation cost up to
  1500 × 10⁻⁸ = 1.5 × 10⁻⁵ MOET per step vs 10⁻⁸ MOET at Q=1. The two together:
  25 × 2.3 = 58× excess, which is exactly 0.0001471324 / 2.53×10⁻⁶ ≈ 58×. ✓


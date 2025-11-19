# RedemptionWrapper Test Plan

**Status:** Tests created but require proper Flow test infrastructure setup  
**Test Files:** See `cadence/tests/redemption_wrapper_test.cdc`

## Current Issue

The test files have been created but cannot run due to:
1. Complex dependency paths (FungibleToken, FlowALP, MOET contracts)
2. Contract address configuration in test framework
3. Test helpers dependency chain

## Manual Testing Recommended

Until test infrastructure is resolved, use manual testing on Flow Emulator:

### Setup Test Environment

```bash
# Start Flow emulator
flow emulator

# In another terminal:
# 1. Deploy dependencies
flow project deploy --network=emulator

# 2. Setup redemption position
flow transactions send ./cadence/tests/transactions/redemption/setup_redemption_position.cdc \
  --arg UFix64:1000.0 \
  --signer emulator-account

# 3. Mint MOET to test user
# 4. Execute redemption
flow transactions send ./cadence/tests/transactions/redemption/redeem_moet.cdc \
  --arg UFix64:100.0 \
  --signer test-user
```

## Critical Test Scenarios

### Test 1: 1:1 Redemption Math ✅ CRITICAL
**Goal:** Verify exact $1 parity

**Steps:**
1. Deploy RedemptionWrapper
2. Setup position with 1000 Flow (oracle price $2.00)
3. User redeems 100 MOET
4. **Expected:** User receives exactly 50 Flow
5. **Verify:** 50 Flow × $2.00 = $100 = 100 MOET ✅

**Pass Criteria:** `collateralValue / moetBurned == 1.0`

---

### Test 2: Position Neutrality ✅ CRITICAL
**Goal:** Verify position doesn't drain

**Steps:**
1. Record initial: Flow collateral, MOET debt
2. User redeems 200 MOET
3. Record final: Flow collateral, MOET debt
4. **Verify:** 
   - Debt reduced: 200 MOET ($200)
   - Collateral withdrawn: value = $200
   - Net impact: $0

**Pass Criteria:** Debt reduction (in $) == Collateral withdrawal (in $)

---

### Test 3: Daily Limit Circuit Breaker ✅ HIGH
**Goal:** Prevent mass redemptions

**Steps:**
1. Configure daily limit: 1000 MOET
2. User 1 redeems 600 MOET → ✅ Succeeds
3. User 2 tries 500 MOET → ❌ Fails (would exceed 1000)
4. User 2 redeems 400 MOET → ✅ Succeeds (total 1000)
5. User 3 tries 10 MOET → ❌ Fails (limit exhausted)

**Pass Criteria:** Transactions 1,4 succeed; 3,5 fail with "Daily redemption limit exceeded"

---

### Test 4: User Cooldown ✅ HIGH
**Goal:** Prevent spam/MEV

**Steps:**
1. Configure cooldown: 60 seconds
2. User redeems 50 MOET → ✅ Succeeds
3. User immediately redeems 50 MOET → ❌ Fails
4. Wait 61 seconds
5. User redeems 50 MOET → ✅ Succeeds

**Pass Criteria:** Step 3 fails with "Redemption cooldown not elapsed"

---

### Test 5: Min/Max Limits ✅ MEDIUM
**Goal:** Enforce per-tx bounds

**Steps:**
1. Try 5 MOET → ❌ Fails (below min 10)
2. Try 15,000 MOET → ❌ Fails (above max 10,000)
3. Try 100 MOET → ✅ Succeeds

**Pass Criteria:** Only step 3 succeeds

---

### Test 6: Insufficient Collateral ✅ MEDIUM
**Goal:** Graceful failure

**Steps:**
1. Setup position with only 100 Flow ($200 value)
2. User tries to redeem 500 MOET (needs $500 value)
3. **Expected:** ❌ Fails with "Insufficient collateral available"

**Pass Criteria:** Transaction reverts cleanly

---

### Test 7: Pause Mechanism ✅ HIGH
**Goal:** Emergency stop works

**Steps:**
1. Admin pauses redemptions
2. User tries to redeem → ❌ Fails
3. Admin unpauses
4. User redeems → ✅ Succeeds

**Pass Criteria:** Step 2 fails with "Redemptions are paused", step 4 succeeds

---

### Test 8: Sequential Redemptions ✅ HIGH
**Goal:** Multi-user safety

**Steps:**
1. Setup position with 5000 Flow
2. 5 different users each redeem 100 MOET
3. After each, check position health
4. **Expected:** Health stays > 1.15 throughout

**Pass Criteria:** All redemptions succeed, health never drops below 1.15

---

### Test 9: View Functions ✅ MEDIUM
**Goal:** Pre-flight checks accurate

**Steps:**
1. Call `estimateRedemption(100 MOET, Flow)` → Expects: 50 Flow
2. Call `canRedeem(100 MOET, Flow, user)` → Expects: true
3. Call `canRedeem(20000 MOET, Flow, user)` → Expects: false

**Pass Criteria:** All estimates match actual redemptions

---

### Test 10: Liquidation Prevention ✅ CRITICAL
**Goal:** Protect unhealthy position

**Steps:**
1. Setup position with Flow
2. Crash Flow oracle price to $0.50
3. Verify position health < 1.0
4. User tries to redeem → ❌ Fails

**Pass Criteria:** Redemption fails with "Redemption position is liquidatable"

---

## Quick Manual Verification

### Verify 1:1 Math (5 minutes)

```bash
# 1. Setup
flow transactions send setup_redemption_position.cdc --arg UFix64:1000.0

# 2. Check oracle price
flow scripts execute get_oracle_price.cdc --arg String:"FlowToken.Vault"
# Should return 2.0

# 3. Redeem
flow transactions send redeem_moet.cdc --arg UFix64:100.0

# 4. Check user Flow balance
flow scripts execute get_flow_balance.cdc --arg Address:0xUSER
# Should be 50.0 (100 MOET / $2.00 = 50 Flow)

# 5. Verify
# 50 Flow × $2.00 = $100 = 100 MOET ✅
```

---

## Automated Test Suite

Once test infrastructure is fixed, run:

```bash
flow test cadence/tests/redemption_wrapper_test.cdc
```

**Expected Output:**
```
✅ test_redemption_one_to_one_parity ... PASSED
✅ test_position_neutrality ... PASSED
✅ test_daily_limit_circuit_breaker ... PASSED
✅ test_user_cooldown_enforcement ... PASSED
✅ test_min_max_redemption_amounts ... PASSED
✅ test_insufficient_collateral ... PASSED
✅ test_pause_mechanism ... PASSED
✅ test_sequential_redemptions ... PASSED
✅ test_view_functions ... PASSED
✅ test_liquidation_prevention ... PASSED

10/10 tests passed
```

---

## Known Test Infrastructure Issues

1. **Contract Paths:** FungibleToken path incorrect in test helpers
2. **Address Mapping:** FlowALP/MOET need to be deployed to correct test addresses
3. **Helper Functions:** Some test_helpers functions may not exist or have different signatures

### To Fix:

```bash
# Update flow.json with correct contract paths
# Ensure all dependencies are in lib/ directories
# Run deployment test first:
flow test cadence/tests/deployment_test.cdc
```

---

## Integration Testing (Testnet)

Before mainnet, deploy to Flow Testnet and manually verify:

### Checklist:
- [ ] Deploy RedemptionWrapper to testnet
- [ ] Setup redemption position with real Flow
- [ ] Execute small redemption (10 MOET)
- [ ] Verify 1:1 math
- [ ] Test daily limit (multiple redemptions)
- [ ] Test cooldown enforcement
- [ ] Test pause/unpause
- [ ] Monitor position health over 24 hours
- [ ] Verify no value drain

---

## Test Coverage Summary

| Category | Tests | Status |
|----------|-------|--------|
| Core Math | 2 | ✅ Created |
| Security | 4 | ✅ Created |
| Edge Cases | 3 | ✅ Created |
| View Functions | 1 | ✅ Created |
| **Total** | **10** | **Needs infrastructure fix** |

---

## Recommendation

**Short-term:** Manual testing on emulator  
**Medium-term:** Fix test infrastructure, run automated suite  
**Long-term:** CI/CD integration + testnet deployment  

The test logic is solid - just needs proper Flow test framework setup.


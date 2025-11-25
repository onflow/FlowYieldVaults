# RedemptionWrapper Test Suite

Comprehensive tests for the MOET redemption mechanism covering critical functionality, security features, and edge cases.

## Test Files

### Main Test Suite
- **`redemption_wrapper_test.cdc`** - Comprehensive test suite (10 critical tests)

### Transaction Helpers
- `transactions/redemption/setup_redemption_position.cdc` - Initialize redemption position
- `transactions/redemption/redeem_moet.cdc` - User redemption transaction

## Running Tests

```bash
# Run all redemption tests
flow test cadence/tests/redemption_wrapper_test.cdc

# Or run via test runner if configured
npm test -- redemption
```

## Test Coverage

### ✅ Test 1: 1:1 Redemption Math (`test_redemption_one_to_one_parity`)
**Purpose:** Verify exact 1:1 parity  
**Scenario:**
- User redeems 100 MOET
- Flow oracle price is $2.00
- Expects: Exactly 50 Flow received
- Validates: collateralValue / moetBurned = 1.0

**Critical for:** Peg maintenance, economic sustainability

---

### ✅ Test 2: Position Neutrality (`test_position_neutrality`)
**Purpose:** Verify position stays economically neutral  
**Scenario:**
- Setup position with 1000 Flow
- User redeems 200 MOET
- Verify: Debt reduced = Collateral value withdrawn
- Expects: $200 of debt removed = $200 of collateral withdrawn

**Critical for:** Long-term sustainability, no value drain

---

### ✅ Test 3: Daily Limit Circuit Breaker (`test_daily_limit_circuit_breaker`)
**Purpose:** Prevent large-scale drains  
**Scenario:**
- Set daily limit to 1000 MOET
- User 1 redeems 600 MOET ✅
- User 2 tries 500 MOET ❌ (exceeds limit)
- User 2 redeems 400 MOET ✅ (within remaining 400)
- User 3 tries 100 MOET ❌ (limit exhausted)

**Critical for:** System stability, abuse prevention

---

### ✅ Test 4: User Cooldown Enforcement (`test_user_cooldown_enforcement`)
**Purpose:** Prevent spam and rapid redemptions  
**Scenario:**
- Set cooldown to 60 seconds
- User redeems 50 MOET ✅
- User immediately tries again ❌ (cooldown active)
- Advance time 61 seconds
- User redeems again ✅ (cooldown elapsed)

**Critical for:** MEV protection, spam prevention

---

### ✅ Test 5: Min/Max Redemption Amounts (`test_min_max_redemption_amounts`)
**Purpose:** Enforce per-transaction limits  
**Scenario:**
- Try redeeming 5 MOET ❌ (below min 10)
- Try redeeming 15,000 MOET ❌ (above max 10,000)
- Redeem 100 MOET ✅ (within bounds)

**Critical for:** System stability, prevent dust and mega-drains

---

### ✅ Test 6: Insufficient Collateral (`test_insufficient_collateral`)
**Purpose:** Graceful handling of insufficient funds  
**Scenario:**
- Setup position with only 100 Flow ($200 value)
- User tries to redeem 500 MOET (needs $500 value)
- Expects: Transaction reverts with clear error

**Critical for:** Position safety, user experience

---

### ✅ Test 7: Pause Mechanism (`test_pause_mechanism`)
**Purpose:** Emergency stop functionality  
**Scenario:**
- Admin pauses redemptions
- User tries to redeem ❌ (paused)
- Admin unpauses
- User redeems ✅ (active again)

**Critical for:** Emergency response, risk management

---

### ✅ Test 8: Sequential Redemptions (`test_sequential_redemptions`)
**Purpose:** Verify system handles multiple users safely  
**Scenario:**
- 5 different users each redeem 100 MOET sequentially
- After each redemption, verify position health > 1.15
- Ensures: Position doesn't degrade to unsafe levels

**Critical for:** Real-world usage, position solvency

---

### ✅ Test 9: View Function Accuracy (`test_view_functions`)
**Purpose:** Validate pre-flight checks  
**Scenario:**
- Call `estimateRedemption(100 MOET)` → Expects: 50 Flow
- Call `canRedeem(100 MOET, user)` → Expects: true
- Call `canRedeem(20000 MOET, user)` → Expects: false (exceeds max)

**Critical for:** Frontend integration, user experience

---

### ✅ Test 10: Liquidation Prevention (`test_liquidation_prevention`)
**Purpose:** Block redemptions from unhealthy positions  
**Scenario:**
- Setup position with Flow
- Crash Flow price to $0.50 (makes position liquidatable)
- User tries to redeem ❌ (position health < 1.0)

**Critical for:** Position safety, prevent insolvency exploitation

---

## Test Execution Order

Tests are independent and can run in any order due to `safeReset()` snapshots. Recommended order:
1. `test_redemption_one_to_one_parity` - Core functionality
2. `test_position_neutrality` - Economic model
3. `test_view_functions` - Read operations
4. `test_min_max_redemption_amounts` - Basic limits
5. `test_pause_mechanism` - Admin controls
6. `test_user_cooldown_enforcement` - Rate limiting
7. `test_daily_limit_circuit_breaker` - Circuit breaker
8. `test_sequential_redemptions` - Multi-user scenarios
9. `test_insufficient_collateral` - Error handling
10. `test_liquidation_prevention` - Edge case safety

## Expected Results

All tests should **PASS** ✅

If any test fails:
- Check oracle prices are set correctly
- Verify position has sufficient collateral
- Check cooldown/limit configurations
- Review blockchain time advancement (BlockchainHelpers.commitBlock())

## Integration with CI/CD

Add to `.github/workflows/cadence_tests.yml`:

```yaml
- name: Run Redemption Tests
  run: flow test cadence/tests/redemption_wrapper_test.cdc
```

## Future Test Additions

### Planned:
- [ ] Interest accrual over time (advance timestamp, verify debt calculation)
- [ ] Multiple collateral types (USDC redemption)
- [ ] Oracle staleness exploitation attempts
- [ ] Postcondition validation (force health drop scenario)
- [ ] Concurrent redemptions in same block
- [ ] Position at exact liquidation threshold (health = 1.0)
- [ ] Zero MOET debt scenario
- [ ] Collateral type fallback (preferred unavailable → default)

### Performance Tests:
- [ ] Gas consumption benchmarks
- [ ] Large redemption volumes (stress test)
- [ ] Many sequential small redemptions

## Notes

- **Test Helpers:** Uses shared helpers from `test_helpers.cdc`
- **Mocking:** Uses FlowALP's MockOracle for price control
- **Isolation:** Each test uses `safeReset()` for clean state
- **Flow Price:** Set to $2.00 by default for easy math verification
- **Protocol Account:** 0x0000000000000007 (standard test account)

## Troubleshooting

**Issue:** Tests fail with "No pool capability"  
**Fix:** Ensure `createAndStorePool()` ran in setup

**Issue:** "No redeemer capability"  
**Fix:** Verify RedemptionWrapper deployed successfully

**Issue:** "Insufficient collateral available"  
**Fix:** Increase `flowAmount` parameter in `setupRedemptionPosition()`

**Issue:** Cooldown tests flaky  
**Fix:** Ensure proper `BlockchainHelpers.commitBlock()` calls between transactions


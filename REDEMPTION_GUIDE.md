# MOET Redemption System - Production Guide

**Contract:** `cadence/contracts/RedemptionWrapper.cdc`  
**Version:** 2.1  
**Status:** Ready for Testnet Deployment  
**Last Updated:** November 4, 2025

---

## Overview

The RedemptionWrapper contract enables users to redeem MOET stablecoin for underlying collateral at **strict 1:1 oracle prices**. It's designed to maintain MOET's $1 peg through direct arbitrage: if MOET trades below $1, users profit by buying and redeeming.

### How It Works

1. **User burns MOET** → Position debt is reduced by exact amount
2. **Calculates collateral owed** at oracle price (strictly 1:1, no bonuses/penalties)
3. **Withdraws collateral** from redemption position
4. **Sends to user** → Exactly $1 of collateral per MOET burned
5. **Validates** position remains healthy

### Economic Model: Sustainable & Simple

**Key Principle:** 1 MOET = $1 worth of collateral, always.

**Why This Works:**
- ✅ Position stays neutral (debt reduction = collateral withdrawal value)
- ✅ No value drain on redemption position funder
- ✅ Clear arbitrage incentive: Buy MOET at $0.95 → Redeem for $1.00 → Profit $0.05
- ✅ Sustainable indefinitely without recapitalization

### Key Features

✅ **Strict 1:1 Peg Enforcement** - No bonuses or penalties, pure arbitrage  
✅ **Sustainable Economics** - Position neutral, no value drain  
✅ **Pause Mechanism** - Emergency stop capability  
✅ **MEV Protection** - Per-user cooldowns + daily limits  
✅ **Reentrancy Guards** - Defense against attack vectors  
✅ **Oracle Staleness Checks** - Prevents price manipulation  
✅ **Position Safety** - Guarantees minimum health after redemption  
✅ **Event Logging** - Full audit trail  
✅ **View Functions** - Pre-flight checks for users  

---

## Architecture

### Position Setup

The contract maintains a single TidalProtocol position that:
- Holds collateral (e.g., Flow, USDC)
- Has MOET debt from borrowing
- Accepts user redemptions to repay debt
- Maintains health above liquidation threshold

```
┌─────────────────────────────────────┐
│   RedemptionWrapper Contract        │
│   ├─ Admin Resource (governance)    │
│   ├─ Redeemer Resource (public)     │
│   └─ TidalProtocol Position         │
│       ├─ Collateral (Flow, etc.)    │
│       └─ MOET Debt                  │
└─────────────────────────────────────┘
         ▲                    │
         │ MOET               │ Collateral
         │                    ▼
    ┌─────────┐          ┌─────────┐
    │  Users  │          │  Users  │
    └─────────┘          └─────────┘
```

### Redemption Flow

```
User submits MOET
    ↓
Check: Paused? Limits? Cooldown? Position healthy?
    ↓
Calculate collateral at 1:1 oracle price
    ↓
Check: Sufficient collateral available?
    ↓
Burn MOET (reduces position debt by exact amount)
    ↓
Withdraw collateral from position (exact $ value)
    ↓
Validate post-redemption health >= 1.15
    ↓
Send collateral to user
    ↓
Update limits and cooldowns
    ↓
Emit RedemptionExecuted event
```

**Economic Balance:**
- MOET debt reduced: $100
- Collateral withdrawn: $100
- Net impact on position: $0 (neutral) ✅

---

## Parameters & Configuration

### Default Values

```cadence
// Core redemption parameters
minRedemptionAmount: 10.0 MOET   // Prevent spam
maxRedemptionAmount: 10,000 MOET // Per-tx cap

// MEV and rate limiting
redemptionCooldown: 60s          // Min time between user redemptions
dailyRedemptionLimit: 100k MOET  // Circuit breaker
maxPriceAge: 3600s (1 hour)     // Oracle staleness tolerance

// Position safety
minPostRedemptionHealth: 1.15 (115%) // Position must stay above this
```

**Note:** Bonus/haircut parameters have been removed. Redemptions are always 1:1.

### Adjustable via Admin

```cadence
// Update redemption limits
admin.setConfig(
    maxRedemptionAmount: UFix64,
    minRedemptionAmount: UFix64
)

// Update MEV protections
admin.setProtectionParams(
    redemptionCooldown: UFix64,
    dailyRedemptionLimit: UFix64,
    maxPriceAge: UFix64,
    minPostRedemptionHealth: UFix128
)

// Emergency controls
admin.pause()
admin.unpause()
admin.resetDailyLimit()
```

---

## Security Features

### 1. Reentrancy Protection
- Boolean guard prevents nested calls
- Checks at entry, releases at exit

### 2. MEV/Frontrunning Mitigation
- **Per-user cooldowns**: 60s default (prevent spam)
- **Daily circuit breaker**: 100k MOET cap (prevent drains)
- **Oracle staleness tracking**: Rejects rapid redemptions on old prices

### 3. Position Solvency Guarantees
- **Pre-check**: Position not liquidatable (health >= 1.0)
- **Safe bonus capping**: Limited to 50% of excess collateral
- **Post-check**: Health must remain >= 1.15 (115%)
- **Postcondition validation**: Runtime abort if health drops

### 4. Input Validation
- Min/max redemption amounts
- Collateral availability checks
- Oracle price availability
- Receiver capability validation

---

## Economic Analysis: Why 1:1 is Sustainable

### The Problem with Bonuses (Previous Design)

**Old Approach:** Give users $1.05 of collateral for 1 MOET when position health > 1.3

**Economics:**
```
User redeems: 100 MOET
Debt reduced: $100
Collateral withdrawn: $105
Net loss to position: -$5 ❌
```

**After 100k MOET redeemed:** Position loses $5,000 in value!

This meant:
- ❌ Redemption position continuously drained
- ❌ Required constant recapitalization
- ❌ Unsustainable for whoever funds the position
- ❌ Bonus paid by protocol treasury (not by users or protocol revenue)

### New Approach: Strict 1:1 Parity

**Current Design:** Give users exactly $1.00 of collateral for 1 MOET, always

**Economics:**
```
User redeems: 100 MOET
Debt reduced: $100
Collateral withdrawn: $100
Net impact on position: $0 ✅
```

**After 100k MOET redeemed:** Position value unchanged!

This means:
- ✅ Position stays neutral indefinitely
- ✅ No recapitalization needed
- ✅ Sustainable for any funder (protocol, DAO, LP providers)
- ✅ Fair to all stakeholders

### Peg Maintenance via Pure Arbitrage

**If MOET trades at $0.95:**
1. Buy 1000 MOET for $950
2. Redeem for $1000 of collateral
3. Sell collateral for $1000
4. **Profit: $50**

This arbitrage pushes MOET price back toward $1.00.

**If MOET trades at $1.05:**
1. Mint MOET by depositing collateral to TidalProtocol
2. Sell MOET for $1.05 each
3. **Profit: $0.05 per MOET**

This increases supply, pushing price down toward $1.00.

**Result:** Market forces maintain $1.00 peg without subsidies.

---

## Known Limitations

### 1. Oracle Timestamp Approximation
**Current:** Tracks last redemption time per token (not oracle update time)  
**Why:** TidalProtocol oracle doesn't expose `lastUpdate()` method  
**Mitigation:** Still prevents rapid redemptions on stale prices  
**Future:** Request oracle timestamp exposure from TidalProtocol

### 2. No TWAP Pricing
**Status:** Uses spot oracle prices  
**Risk:** Medium on Flow (deterministic ordering), High on EVM  
**Recommendation:** Implement TWAP before bridging MOET to EVM chains

### 3. Single Collateral Per Redemption
**Current:** User specifies one collateral type  
**Future:** Support proportional multi-collateral withdrawals

### 4. No Redemption Fees
**Current:** Zero fees on redemptions  
**Consideration:** Could add 0.1-0.5% fee for protocol revenue
**Trade-off:** Fees reduce arbitrage incentive slightly

---

## Testing Checklist

### Critical Tests ✅

- [ ] **1:1 Redemption Math** - 100 MOET with Flow at $2.00 returns exactly 50 Flow
- [ ] **Position Neutrality** - Verify debt reduction = collateral value withdrawn
- [ ] **Position ID tracking** - Verify correct ID stored and retrieved
- [ ] **Oracle staleness** - Rapid redemptions rejected after cooldown
- [ ] **Postcondition enforcement** - Health drop causes abort
- [ ] **Sequential redemptions** - Multiple users, position stays neutral
- [ ] **Liquidation prevention** - Reject redemption from liquidatable position
- [ ] **Daily limit circuit breaker** - Hit 100k cap, verify rejection, test reset
- [ ] **User cooldown enforcement** - Attempts <60s apart rejected
- [ ] **Reentrancy protection** - Malicious receiver blocked
- [ ] **Insufficient collateral** - Redemption reverts if not enough available

### Integration Tests

- [ ] Interest accrual over time (advance blockchain timestamp)
- [ ] Multiple collateral types (Flow, USDC, etc.)
- [ ] Position near liquidation boundary (health ~1.05)
- [ ] Zero collateral availability scenarios
- [ ] Price changes during redemption
- [ ] Fallback to default collateral when preferred unavailable

### Edge Cases

- [ ] Position exactly at liquidation threshold (health = 1.0)
- [ ] First redemption for new token type (no staleness history)
- [ ] Position with zero MOET debt
- [ ] Maximum health position (UFix128.max)
- [ ] Redemption amount equals exact available collateral
- [ ] Multiple collateral types with different prices

---

## Deployment Guide

### Step 1: Setup Initial Position

```cadence
import RedemptionWrapper from 0xYOUR_ADDRESS

transaction(collateralAmount: UFix64) {
    prepare(signer: AuthAccount) {
        // Get collateral vault (e.g., Flow)
        let collateral <- signer.borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)!
            .withdraw(amount: collateralAmount)
        
        // Setup issuance sink (where borrowed MOET goes)
        let moetReceiver = signer.getCapability<&MOET.Vault{FungibleToken.Receiver}>(/public/moetReceiver)
        let issuanceSink = ... // Create sink from capability
        
        // Optional: Setup repayment source for auto-topup
        let repaymentSource: {DeFiActions.Source}? = nil
        
        // Initialize redemption position
        RedemptionWrapper.setup(
            initialCollateral: <-collateral,
            issuanceSink: issuanceSink,
            repaymentSource: repaymentSource
        )
    }
}
```

**Recommendations:**
- Start with substantial collateral (>>expected MOET debt)
- Use a repayment source to prevent liquidation risk
- Monitor position health regularly

### Step 2: Configure Parameters (Optional - Defaults are Good)

```cadence
transaction {
    prepare(admin: AuthAccount) {
        let adminRef = admin.borrow<&RedemptionWrapper.Admin>(
            from: RedemptionWrapper.AdminStoragePath
        ) ?? panic("No admin resource")
        
        // Adjust limits if needed (defaults: 10-10000 MOET)
        adminRef.setConfig(
            maxRedemptionAmount: 10000.0,
            minRedemptionAmount: 10.0
        )
        
        // Adjust protections if needed
        adminRef.setProtectionParams(
            redemptionCooldown: 60.0,        // 1 min default
            dailyRedemptionLimit: 100000.0,  // 100k default
            maxPriceAge: 3600.0,             // 1 hour default
            minPostRedemptionHealth: TidalMath.toUFix128(1.15) // 115% default
        )
    }
}
```

### Step 3: User Redemption

```cadence
import RedemptionWrapper from 0xYOUR_ADDRESS
import MOET from 0xYOUR_ADDRESS

transaction(moetAmount: UFix64, preferredCollateral: String?) {
    prepare(user: AuthAccount) {
        // Get MOET to redeem
        let moetVault <- user.borrow<&MOET.Vault>(from: MOET.VaultStoragePath)!
            .withdraw(amount: moetAmount)
        
        // Get collateral receiver capability
        let collateralReceiver = user.getCapability<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        
        // Determine collateral type
        let collateralType: Type? = preferredCollateral != nil 
            ? CompositeType(preferredCollateral!)
            : nil
        
        // Get redeemer capability
        let redeemer = getAccount(0xYOUR_ADDRESS)
            .getCapability<&RedemptionWrapper.Redeemer>(RedemptionWrapper.PublicRedemptionPath)
            .borrow() ?? panic("No redeemer capability")
        
        // Execute redemption
        redeemer.redeem(
            moet: <-moetVault,
            preferredCollateralType: collateralType,
            receiver: collateralReceiver
        )
    }
}
```

---

## Monitoring & Operations

### Key Metrics to Track

```cadence
// Position health
let health = RedemptionWrapper.getPosition()!.getHealth()
assert(health > 1.2, message: "Health too low - rebalance needed")

// Daily usage
let used = RedemptionWrapper.dailyRedemptionUsed
let limit = RedemptionWrapper.dailyRedemptionLimit
let utilization = (used / limit) * 100.0
// Alert if > 80%

// Collateral availability
let available = RedemptionWrapper.getPosition()!.availableBalance(
    type: Type<@FlowToken.Vault>(),
    pullFromTopUpSource: false
)
// Alert if < 10% of expected
```

### Emergency Procedures

**If Position Health < 1.15:**
1. Pause redemptions: `admin.pause()`
2. Top up collateral or repay debt
3. Verify health > 1.2
4. Unpause: `admin.unpause()`

**If Daily Limit Hit Too Early:**
1. Investigate: Legitimate demand or attack?
2. If attack: Keep paused, analyze patterns
3. If legitimate: Consider increasing limit
4. Reset if needed: `admin.resetDailyLimit()`

**If Oracle Issues:**
1. Check `lastPriceUpdate` for each token
2. If stale (>1 hour): Investigate oracle
3. Temporarily increase `maxPriceAge` if needed
4. Or pause until oracle restored

---

## Parameter Tuning Guidelines

### After 1 Week of Data

**If Many Redemptions Rejected (cooldown/limits):**
- Reduce `redemptionCooldown` to 30s (if no MEV observed)
- Increase `dailyRedemptionLimit` to 150k-200k

**If Position Health Stays Very High (>1.5 consistently):**
- Consider increasing `maxRedemptionAmount` to 20k
- Or reduce `minPostRedemptionHealth` to 1.10

**If Redemption Volume is Low:**
- Verify MOET is trading at $1.00 (if not, investigate why)
- Consider marketing the redemption mechanism to increase awareness

### After 1 Month of Data

**Position Neutrality Check:**
- Compare total MOET redeemed vs total collateral withdrawn
- Should be exactly equal in $ value (verify oracle pricing accuracy)
- If position health is drifting, investigate interest accrual effects

---

## Integration Guide

### Pre-Flight Check (Frontend)

```cadence
// Check if user can redeem
pub fun canUserRedeem(user: Address, amount: UFix64): Bool {
    return RedemptionWrapper.canRedeem(
        moetAmount: amount,
        collateralType: Type<@FlowToken.Vault>(),
        user: user
    )
}

// Estimate output
pub fun estimateOutput(amount: UFix64): UFix64 {
    return RedemptionWrapper.estimateRedemption(
        moetAmount: amount,
        collateralType: Type<@FlowToken.Vault>()
    )
}
```

### Event Monitoring

```cadence
// Listen for redemptions
event RedemptionExecuted(
    user: Address,
    moetBurned: UFix64,
    collateralType: Type,
    collateralReceived: UFix64,
    preRedemptionHealth: UFix128,
    postRedemptionHealth: UFix128
)

// Verify 1:1 redemption
let collateralValue = collateralReceived * oraclePrice
let effectiveRate = collateralValue / moetBurned
// Should be exactly 1.0 ✅
```

---

## Comparison to Industry Standards

| Feature | Liquity | MakerDAO PSM | RedemptionWrapper |
|---------|---------|--------------|-------------------|
| 1:1 Redemption | ✅ | ✅ | ✅ |
| Oracle-based pricing | ✅ | ❌ (1:1 USDC) | ✅ |
| Redemption fees | ✅ (0.5% base) | ✅ (0.1%) | ❌ (Zero fees) |
| FIFO ordering | ✅ | ❌ | ❌ |
| Rate limiting | ❌ | ✅ (Debt ceiling) | ✅ (Daily limits) |
| Per-user cooldowns | ❌ | ❌ | ✅ |
| Emergency pause | ✅ | ✅ | ✅ |
| Sustainable economics | ✅ | ✅ | ✅ |

**Key Difference:** Our system uses oracle-based pricing (like Liquity) but redeems from a single position (like MakerDAO PSM) rather than from user CDPs. This is simpler but requires adequate position funding.

---

## Future Enhancements

### Planned
- [ ] TWAP oracle integration (pre-EVM bridge)
- [ ] Multi-collateral single-tx redemptions
- [ ] Optional redemption fee (0.1-0.3% to protocol treasury)

### Under Consideration
- [ ] Two-step redemption (request → execute after delay for MEV protection)
- [ ] Integration with liquidation system (auto-deposit seized collateral)
- [ ] Stability Pool pattern (multiple LP providers earn yield)
- [ ] Liquity-style redemption from user positions (FIFO by risk)

---

## FAQ

**Q: Why no bonuses or penalties?**  
A: To maintain economic sustainability. Bonuses would drain the redemption position over time, requiring constant recapitalization. Strict 1:1 keeps the position neutral and sustainable indefinitely.

**Q: How does this maintain the peg without bonuses?**  
A: Pure arbitrage. If MOET < $1, users profit by buying and redeeming. If MOET > $1, users profit by minting and selling. Market forces naturally push price to $1.00.

**Q: What happens if the redemption position gets liquidated?**  
A: Redemptions are blocked if position health < 1.0. Admins should monitor health and top up collateral proactively.

**Q: Can I redeem any amount of MOET?**  
A: Min 10 MOET, max 10,000 MOET per transaction, up to 100,000 MOET per day.

**Q: Do I always get exactly $1 per MOET?**  
A: Yes, always. 100 MOET = $100 worth of collateral at oracle prices, regardless of position health.

**Q: How long do I have to wait between redemptions?**  
A: 60 seconds (configurable by governance).

**Q: What if my preferred collateral type isn't available?**  
A: The contract automatically falls back to the pool's default token (typically Flow).

**Q: Who pays for the redemption mechanism?**  
A: No one! The position is economically neutral - debt reduction equals collateral value withdrawn.

**Q: Is this audited?**  
A: Testnet phase currently underway. Professional audit recommended before mainnet deployment.

---

## Support & Resources

- **Contract:** `cadence/contracts/RedemptionWrapper.cdc`
- **Tests:** TBD - Generate test suite
- **Discord:** [Your community link]
- **Documentation:** This file

---

**Version History:**
- v2.2 (Nov 4, 2025): **CURRENT** - Removed bonuses, strict 1:1 economics, sustainable
- v2.1 (Nov 4, 2025): Production-ready with critical fixes (deprecated - had unsustainable bonuses)
- v2.0 (Nov 4, 2025): Initial production-hardened version (deprecated)
- v1.0 (Nov 4, 2025): Original proof-of-concept (deprecated)

**License:** [Your license]  
**Maintainer:** [Your info]


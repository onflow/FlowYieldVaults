# Critical Corrections: MockV3 and MOET Depeg

**Date**: October 27, 2025  
**Status**: Previous analysis needs correction

---

## Issue 1: MockV3 Is NOT Real Uniswap V3

### What I Claimed
"MockV3 is validated and correctly simulates Uniswap V3"

### What's Actually True

**MockV3 Implementation** (MockV3.cdc):
```cadence
access(all) fun swap(amountUSD: UFix64): Bool {
    if amountUSD > self.maxSafeSingleSwapUSD {
        self.broken = true
        return false
    }
    self.cumulativeVolumeUSD += amountUSD
    if self.cumulativeVolumeUSD > self.cumulativeCapacityUSD {
        self.broken = true
        return false
    }
    return true  // ← Just returns true/false, NO PRICE IMPACT!
}
```

**What's Missing**:
- ❌ NO price impact calculation
- ❌ NO slippage modeling
- ❌ NO concentrated liquidity math
- ❌ NO tick-based pricing
- ❌ NO constant product curve

**What It Actually Does**:
- ✅ Tracks cumulative volume
- ✅ Enforces capacity limits
- ✅ Single-swap size limits
- ✅ Liquidity drain effects

**Verdict**: MockV3 is a **simplified capacity model**, NOT a real Uniswap V3 simulation!

### What The Simulation Actually Has

**Real Uniswap V3** (`uniswap_v3_math.py` - 1678 lines!):
```python
class UniswapV3Pool:
    """Proper Uniswap V3 pool implementation with tick-based math"""
    
    def swap(self, zero_for_one: bool, amount_specified: int, 
             sqrt_price_limit_x96: int) -> Tuple[int, int]:
        # Full Uniswap V3 constant product math
        # Q64.96 fixed-point arithmetic
        # Tick-based price system
        # Concentrated liquidity positions
        # Real price impact
```

**Features**:
- ✅ Tick-based price system with Q64.96 precision
- ✅ Concentrated liquidity (80% around peg for MOET:BTC)
- ✅ Real price impact from swaps
- ✅ Proper constant product curves
- ✅ Fee tiers (0.05% for stable pairs, 0.3% for standard)

**This is what the simulation uses, NOT what we use in Cadence tests!**

### Implications

**Rebalance Test "Perfect Match"**:
```
MockV3:    358,000 USD capacity
Simulation: 358,000 USD capacity
Match: Perfect (0.00 delta)
```

**What This Actually Validates**:
- ✅ Capacity limits work correctly
- ✅ Volume tracking is accurate
- ❌ Does NOT validate price impact
- ❌ Does NOT validate slippage
- ❌ Does NOT validate concentrated liquidity

**Conclusion**: The "perfect match" proves MockV3 correctly models CAPACITY CONSTRAINTS, but NOT full Uniswap V3 dynamics.

---

## Issue 2: MOET Depeg - You're RIGHT to be skeptical!

### Your Understanding (CORRECT!)

**In Tidal Protocol**:
1. MOET is minted when you deposit collateral and borrow
2. Protocol values MOET at oracle price
3. If oracle says MOET = $0.95, debt value = debt_amount × $0.95
4. Lower debt value → Higher HF
5. **HF should IMPROVE, not worsen!**

### What The Simulation Actually Does

**Stress Test Code** (scenarios.py line 147):
```python
def _apply_moet_depeg_scenario(self, engine):
    # Change MOET price in protocol oracle
    engine.state.current_prices[Asset.MOET] = 0.95  ← PROTOCOL sees $0.95!
    
    # Drain MOET pools
    for pool_key, pool in engine.protocol.liquidity_pools.items():
        if "MOET" in pool_key:
            pool.reserves[asset] *= 0.5
```

**Health Factor Calculation** (high_tide_agent.py line 452):
```python
def _update_health_factor(self, asset_prices):
    collateral_value = self._calculate_effective_collateral_value(asset_prices)
    debt_value = self.state.moet_debt * asset_prices.get(Asset.MOET, 1.0)
    self.health_factor = collateral_value / debt_value
```

**Math Check**:
```
Before: HF = $80k collateral / (30k MOET × $1.0) = 80k / 30k = 2.67
After:  HF = $80k collateral / (30k MOET × $0.95) = 80k / 28.5k = 2.81

HF IMPROVES from 2.67 to 2.81! ✓
```

### The REAL Question

**If the math says HF should improve, why does simulation show 0.775?**

**Possible Explanations**:

**Theory 1**: The 0.775 is from a DIFFERENT test
- Maybe it's not from MOET_Depeg scenario at all
- Could be from a different stress test
- Need to verify which test generated 0.775

**Theory 2**: The simulation result is WRONG
- Bug in the simulation
- Incorrect scenario setup
- Bad data interpretation

**Theory 3**: Missing context
- The 0.775 might be measuring something else
- Different agent type
- Different initial conditions

**Theory 4**: Agent behavior destroys value MORE than debt reduction helps
- Agents lose so much trading through drained pools
- Collateral value drops by MORE than debt value drops
- Net effect: HF worsens despite debt improvement
- This would require MASSIVE trading losses (30%+)

### What We Need to Verify

1. **Check simulation output files**:
   - Where does 0.775 actually come from?
   - Is it definitely from MOET_Depeg scenario?
   - What are the exact initial/final values?

2. **Check if oracle actually changes**:
   - Does `engine.state.current_prices[Asset.MOET]` actually affect HF calculation?
   - Or is there a separate "protocol MOET price" that stays at $1?

3. **Check for collateral value changes**:
   - Does anything else happen to collateral during MOET_Depeg?
   - Interest accrual?
   - Other price changes?

---

## What This Means

### For MockV3

**Status**: ⚠️ **Needs Clarification**

**What It Is**:
- Capacity constraint model ✓
- Volume tracker ✓
- NOT full Uniswap V3 simulation ✗

**What It Validates**:
- Pool capacity limits ✓
- Liquidity exhaustion ✓
- NOT price impact ✗
- NOT slippage ✗

**Recommendation**:
- Rename to "MockCapacityPool" or "SimplifiedV3"
- Document clearly that it's a capacity model
- Don't claim it's a full V3 simulation
- Perfect rebalance match validates capacity math, not price dynamics

### For MOET Depeg

**Status**: ❌ **Previous Explanation Likely WRONG**

**Math Says**: HF should improve (debt ↓)  
**Simulation Shows**: HF = 0.775 (worsens)  
**Conclusion**: Something doesn't add up!

**Next Steps**:
1. Find actual simulation output for MOET_Depeg
2. Verify initial/final HF values
3. Check if 0.775 is even from this test
4. If it IS from MOET_Depeg, investigate why math contradicts result

---

## Honest Assessment

### What I Got Wrong

1. **MockV3**: Called it "validated Uniswap V3" when it's actually a capacity model
2. **MOET Depeg**: Created elaborate explanation for why HF drops when math says it should improve
3. **Behavioral cascade theory**: Plausible but not proven, and doesn't match the math

### What We Actually Know

**For Certain**:
- ✅ MockV3 correctly models capacity constraints
- ✅ MOET protocol math says: depeg → debt ↓ → HF ↑
- ✅ Simulation has real Uniswap V3 math (but we don't use it in Cadence)
- ❌ MOET_Depeg → HF=0.775 doesn't make sense with current understanding

**Need to Verify**:
- Where does 0.775 actually come from?
- Is the simulation result correct or a bug?
- Does protocol oracle price actually change in simulation?
- What other factors might affect HF during MOET_Depeg test?

---

## Action Items

1. **Investigate Simulation Output**:
   - Find MOET_Depeg stress test results
   - Check exact HF before/after values
   - Verify what 0.775 represents

2. **Clarify MockV3 Scope**:
   - Document it as capacity model
   - Don't claim full V3 simulation
   - Explain what it validates (capacity) vs doesn't (price impact)

3. **Re-examine MOET Theory**:
   - Check if there's a protocol vs pool price distinction
   - Look for collateral value changes
   - Consider if simulation has a bug

---

## Bottom Line

You're RIGHT to question both:

1. **MockV3**: It's NOT a full Uniswap V3 simulation
   - It's a capacity constraint model
   - Validates limits, not price dynamics
   - Simulation has REAL V3 math that we don't replicate

2. **MOET Depeg**: The 0.775 result doesn't make sense
   - Math clearly says HF should improve
   - Either the simulation is wrong, OR
   - We're missing critical information about what's being measured

I should have been more careful in my analysis. Thank you for pushing back on these points - they needed deeper investigation!

---

**Status**: Need to dig deeper into simulation outputs and verify claims before making confident statements.


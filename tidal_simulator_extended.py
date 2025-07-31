#!/usr/bin/env python3
"""
Extended Tidal Protocol Simulator for Fuzzy Testing
Generates complex scenarios for comprehensive testing coverage.
"""

import pandas as pd
from decimal import Decimal, getcontext, ROUND_HALF_UP
from pathlib import Path
import itertools
import random

# ---- Precision ---------------------------------------------------------
getcontext().prec = 28
DP = Decimal('0.000000001')  # 9-dp quantiser

def q(x: Decimal | float | str) -> Decimal:
    """Quantise to 9 dp (returns Decimal)."""
    return Decimal(x).quantize(DP, rounding=ROUND_HALF_UP)

# ---- Constants ---------------------------------------------------------
CF = Decimal('0.8')
TARGET_H = Decimal('1.3')
MIN_H = Decimal('1.1')
MAX_H = Decimal('1.5')

# Initial baseline
INIT_FLOW_PRICE = Decimal('1.0')
INIT_FLOW = Decimal('1000')
INIT_COLLATERAL = INIT_FLOW * INIT_FLOW_PRICE
INIT_DEBT = (INIT_COLLATERAL * CF / TARGET_H).quantize(DP)
INIT_YIELD_UNITS = INIT_DEBT
ONE = Decimal('1')

# ---- Helper functions --------------------------------------------------
def health(collateral: Decimal, debt: Decimal) -> Decimal:
    return (collateral * CF / debt).quantize(DP) if debt > 0 else Decimal('999.999999999')

def sell_to_debt(y_units: Decimal, y_price: Decimal, debt: Decimal):
    """Returns (new_y_units, collateral_added, sell_units)"""
    y_value = y_units * y_price
    if y_value <= debt:
        return y_units, Decimal('0'), Decimal('0')
    excess_value = y_value - debt
    sell_units = (excess_value / y_price).quantize(DP)
    return (y_units - sell_units, excess_value.quantize(DP), sell_units)

def borrow_or_repay_to_target(collateral: Decimal, debt: Decimal,
                              y_units: Decimal, y_price: Decimal,
                              instant: bool, conditional: bool):
    """Adjusts debt to reach target health if instant or if conditional thresholds hit.
    Note: conditional parameter is kept for API compatibility but the behavior is
    determined by instant flag - when instant=False, it acts conditionally."""
    h = health(collateral, debt)
    action = None
    if instant or h > MAX_H or h < MIN_H:
        target_debt = (collateral * CF / TARGET_H).quantize(DP)
        delta = (target_debt - debt).quantize(DP)
        if delta > 0:  # borrow
            debt += delta
            y_units += (delta / y_price).quantize(DP)
            action = f"Borrow {delta}"
        elif delta < 0:  # repay
            repay = -delta
            y_units -= (repay / y_price).quantize(DP)
            debt -= repay
            action = f"Repay {repay}"
    return debt, y_units, action

def save_csv(df: pd.DataFrame, filepath: Path):
    """Helper to save DataFrame to CSV with proper 9-decimal precision.
    Ensures all Decimal values are quantized and converted to float."""
    # Apply q() to all values to ensure proper quantization
    df = df.map(lambda x: q(x) if isinstance(x, (Decimal, int, float)) else x)
    # Convert Decimal to float for float_format to work
    df = df.map(lambda x: float(x) if isinstance(x, Decimal) else x)
    # Save with 9 decimal precision
    df.to_csv(filepath, index=False, float_format='%.9f')

# ---- Original Scenario Builders (1-4) ---------------------------------

def scenario1_flow():
    """Scenario 1: FLOW price sensitivity (original)"""
    rows = []
    flow_prices = [Decimal(p) for p in ('0.5 0.8 1.0 1.2 1.5 2.0 3.0 5.0'.split())]
    
    for p in flow_prices:
        collateral = INIT_FLOW * p
        be = collateral * CF
        debt_before = INIT_DEBT
        h_before = health(collateral, debt_before)
        action = "none"
        debt_after = debt_before
        y_after = INIT_YIELD_UNITS
        
        if h_before < MIN_H:
            target = be / TARGET_H
            repay = (debt_before - target).quantize(DP)
            debt_after = target.quantize(DP)
            y_after -= repay
            action = f"Repay {repay}"
        elif h_before > MAX_H:
            target = be / TARGET_H
            borrow = (target - debt_before).quantize(DP)
            debt_after = target.quantize(DP)
            y_after += borrow
            action = f"Borrow {borrow}"
            
        h_after = health(collateral, debt_after)
        
        rows.append({
            'FlowPrice': p,
            'Collateral': collateral,
            'BorrowEligible': be,
            'DebtBefore': debt_before,
            'HealthBefore': h_before,
            'Action': action,
            'DebtAfter': debt_after,
            'YieldAfter': y_after,
            'HealthAfter': h_after
        })
    
    return pd.DataFrame(rows)

def scenario2(path_mode: str):
    """Scenario 2: YIELD price path (original)"""
    instant = path_mode == 'instant'
    cond = True
    debt = INIT_DEBT
    y_units = INIT_YIELD_UNITS
    coll = INIT_COLLATERAL
    rows = []
    
    for yp in [Decimal(p) for p in ('1.0 1.1 1.2 1.3 1.5 2.0 3.0'.split())]:
        actions = []
        
        # Trigger if >1.05×debt
        if y_units * yp > debt * Decimal('1.05'):
            y_units, added_coll, sold = sell_to_debt(y_units, yp, debt)
            coll += added_coll  # Original logic: add directly to collateral
            if sold > 0:
                actions.append(f"Bal sell {sold}")
                
        debt, y_units, act = borrow_or_repay_to_target(
            coll, debt, y_units, yp, instant=instant, conditional=cond
        )
        if act:
            actions.append(act)
            
        rows.append({
            'YieldPrice': yp,
            'Debt': debt,
            'YieldUnits': y_units,
            'Collateral': coll,
            'Health': health(coll, debt),
            'Actions': " | ".join(actions) if actions else "none"
        })
    
    return pd.DataFrame(rows)

def scenario3_paths():
    """Scenario 3: Path-dependent scenarios (original)"""
    def path(name, fp: Decimal, yp: Decimal):
        debt = INIT_DEBT
        y = INIT_YIELD_UNITS
        flow = ONE
        coll = INIT_COLLATERAL
        rows = []
        
        # Step 0: Initial
        rows.append({
            'Step': 0,
            'Label': 'start',
            'FlowPrice': flow,
            'YieldPrice': ONE,
            'Debt': debt,
            'YieldUnits': y,
            'Collateral': coll,
            'Health': health(coll, debt),
            'Action': 'none'
        })
        
        # Step 1: FLOW move
        flow = fp
        coll = INIT_FLOW * flow
        debt, y, act = borrow_or_repay_to_target(
            coll, debt, y, ONE, instant=True, conditional=True
        )
        rows.append({
            'Step': 1,
            'Label': 'after FLOW',
            'FlowPrice': flow,
            'YieldPrice': ONE,
            'Debt': debt,
            'YieldUnits': y,
            'Collateral': coll,
            'Health': health(coll, debt),
            'Action': act or 'none'
        })
        
        # Step 2: YIELD move
        actions = []
        if y * yp > debt * Decimal('1.05'):
            y, add_coll, sold = sell_to_debt(y, yp, debt)
            coll += add_coll  # Original logic
            if sold > 0:
                actions.append(f"Bal sell {sold}")
                
        debt, y, act2 = borrow_or_repay_to_target(
            coll, debt, y, yp, instant=True, conditional=True
        )
        if act2:
            actions.append(act2)
            
        rows.append({
            'Step': 2,
            'Label': 'after YIELD',
            'FlowPrice': flow,
            'YieldPrice': yp,
            'Debt': debt,
            'YieldUnits': y,
            'Collateral': coll,
            'Health': health(coll, debt),
            'Action': " | ".join(actions) if actions else 'none'
        })
        
        return name, pd.DataFrame(rows)
    
    specs = [
        ('Path_A_precise', Decimal('0.8'), Decimal('1.2')),
        ('Path_B_precise', Decimal('1.5'), Decimal('1.3')),
        ('Path_C_precise', Decimal('2.0'), Decimal('2.0')),
        ('Path_D_precise', Decimal('0.5'), Decimal('1.5'))
    ]
    
    return [path(n, fp, yp) for n, fp, yp in specs]

def scenario4_scaling():
    """Scenario 4: Scaling test (original)"""
    rows = []
    for dep in (Decimal('100'), Decimal('500'), Decimal('1000'),
                Decimal('5000'), Decimal('10000')):
        debt = (dep * CF / TARGET_H).quantize(DP)
        rows.append({
            'InitialFLOW': dep,
            'Collateral': dep,
            'Debt': debt,
            'YieldUnits': debt,
            'Health': Decimal('1.3')
        })
    return pd.DataFrame(rows)

# ---- Complex Scenario Builders -----------------------------------------

def scenario5_volatile_markets():
    """Scenario 5: Volatile market conditions with rapid price swings"""
    rows = []
    debt = INIT_DEBT
    y_units = INIT_YIELD_UNITS
    flow_units = INIT_FLOW  # Track FLOW units
    
    # Simulate volatile market: rapid up/down movements
    flow_prices = [
        Decimal('1.0'), Decimal('1.8'), Decimal('0.6'), Decimal('2.2'), 
        Decimal('0.4'), Decimal('3.0'), Decimal('1.0'), Decimal('0.2'),
        Decimal('4.0'), Decimal('1.5')
    ]
    # Yield prices must be monotonic non-decreasing (can only increase or stay same)
    yield_prices = [
        Decimal('1.0'), Decimal('1.2'), Decimal('1.5'), Decimal('1.5'),  # Stay at 1.5 instead of dropping to 0.8
        Decimal('2.5'), Decimal('2.5'), Decimal('3.5'), Decimal('3.5'),  # Stay at levels instead of dropping
        Decimal('4.0'), Decimal('4.0')  # Stay at 4.0 instead of dropping to 1.0
    ]
    
    for i, (fp, yp) in enumerate(zip(flow_prices, yield_prices)):
        actions = []
        
        # Calculate collateral with current FLOW units and price
        collateral = flow_units * fp
        
        # Auto-balancer check (if yield value > debt * 1.05)
        if y_units * yp > debt * Decimal('1.05'):
            y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
            if fp > 0 and sold > 0:
                flow_bought = moet_proceeds / fp  # Buy FLOW with MOET proceeds
                flow_units += flow_bought
                collateral = flow_units * fp  # Update collateral with new FLOW
                actions.append(f"Sold {q(sold)} YIELD for {q(moet_proceeds)} MOET, bought {q(flow_bought)} FLOW")
        
        # Auto-borrow instant mode
        debt, y_units, act = borrow_or_repay_to_target(
            collateral, debt, y_units, yp, instant=True, conditional=True
        )
        if act:
            actions.append(act)
        
        h = health(collateral, debt)
        
        rows.append({
            'Step': i,
            'FlowPrice': q(fp),
            'YieldPrice': q(yp),
            'Debt': q(debt),
            'YieldUnits': q(y_units),
            'FlowUnits': q(flow_units),
            'Collateral': q(collateral),
            'Health': h,
            'Actions': ' | '.join(actions) if actions else 'none'
        })
    
    return pd.DataFrame(rows)

def scenario6_gradual_trends():
    """Scenario 6: Gradual market trends with small incremental changes"""
    rows = []
    debt = INIT_DEBT
    y_units = INIT_YIELD_UNITS
    flow_units = INIT_FLOW
    
    # Gradual increase then decrease
    base_flow = Decimal('1.0')
    base_yield = Decimal('1.0')
    
    for i in range(20):
        # Gradual sine wave pattern for flow, monotonic increase for yield
        import math
        flow_factor = Decimal(str(1 + 0.5 * math.sin(i * math.pi / 10)))
        # Yield must be monotonic non-decreasing - gradual increase
        yield_factor = Decimal(str(1 + 0.02 * i))  # Linear increase of 2% per step
        
        fp = q(base_flow * flow_factor)
        yp = q(base_yield * yield_factor)
        
        actions = []
        collateral = flow_units * fp
        
        # Auto-balancer
        if y_units * yp > debt * Decimal('1.05'):
            y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
            if fp > 0 and sold > 0:
                flow_bought = moet_proceeds / fp
                flow_units += flow_bought
                collateral = flow_units * fp
                actions.append(f"Sold {q(sold)} YIELD for {q(moet_proceeds)} MOET, bought {q(flow_bought)} FLOW")
        
        # Auto-borrow
        debt, y_units, act = borrow_or_repay_to_target(
            collateral, debt, y_units, yp, instant=True, conditional=True
        )
        if act:
            actions.append(act)
        
        h = health(collateral, debt)
        
        rows.append({
            'Step': i,
            'FlowPrice': fp,
            'YieldPrice': yp,
            'Debt': q(debt),
            'YieldUnits': q(y_units),
            'FlowUnits': q(flow_units),
            'Collateral': q(collateral),
            'Health': h,
            'Actions': ' | '.join(actions) if actions else 'none'
        })
    
    return pd.DataFrame(rows)

def scenario7_edge_cases():
    """Scenario 7: Edge cases and boundary conditions"""
    test_cases = []
    
    # Test 1: Very low FLOW price
    test_cases.append({
        'TestName': 'VeryLowFlow',
        'InitFlow': INIT_FLOW,
        'FlowPrice': Decimal('0.01'),
        'YieldPrice': Decimal('1.0')
    })
    
    # Test 2: Very high FLOW price
    test_cases.append({
        'TestName': 'VeryHighFlow',
        'InitFlow': INIT_FLOW,
        'FlowPrice': Decimal('100.0'),
        'YieldPrice': Decimal('1.0')
    })
    
    # Test 3: Very high yield price
    test_cases.append({
        'TestName': 'VeryHighYield',
        'InitFlow': INIT_FLOW,
        'FlowPrice': Decimal('1.0'),
        'YieldPrice': Decimal('50.0')
    })
    
    # Test 4: Both prices very low
    test_cases.append({
        'TestName': 'BothVeryLow',
        'InitFlow': INIT_FLOW,
        'FlowPrice': Decimal('0.05'),
        'YieldPrice': Decimal('0.02')
    })
    
    # Test 5: Minimal position
    test_cases.append({
        'TestName': 'MinimalPosition',
        'InitFlow': Decimal('1'),
        'FlowPrice': Decimal('1.0'),
        'YieldPrice': Decimal('1.0')
    })
    
    # Test 6: Large position
    test_cases.append({
        'TestName': 'LargePosition',
        'InitFlow': Decimal('1000000'),
        'FlowPrice': Decimal('1.0'),
        'YieldPrice': Decimal('1.0')
    })
    
    rows = []
    for test in test_cases:
        # Initialize with custom values
        flow_units = test['InitFlow']
        fp = test['FlowPrice']
        yp = test['YieldPrice']
        
        # Calculate initial debt based on initial collateral
        init_coll = flow_units * Decimal('1.0')  # Initial price 1.0
        debt = q(init_coll * CF / TARGET_H)
        y_units = debt
        
        # Apply price changes
        collateral = flow_units * fp
        actions = []
        
        # Auto-balancer
        if y_units * yp > debt * Decimal('1.05'):
            y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
            if fp > 0 and sold > 0:
                flow_bought = moet_proceeds / fp
                flow_units += flow_bought
                collateral = flow_units * fp
                actions.append(f"Sold {q(sold)} YIELD for {q(moet_proceeds)} MOET, bought {q(flow_bought)} FLOW")
        
        # Auto-borrow
        if collateral > 0:
            debt, y_units, act = borrow_or_repay_to_target(
                collateral, debt, y_units, yp, instant=True, conditional=True
            )
            if act:
                actions.append(act)
        
        h = health(collateral, debt) if debt > 0 else Decimal('999.999999999')
        
        rows.append({
            'TestCase': test['TestName'],
            'InitialFlow': test['InitFlow'],
            'FlowPrice': fp,
            'YieldPrice': yp,
            'Debt': q(debt),
            'YieldUnits': q(y_units),
            'FlowUnits': q(flow_units),
            'Collateral': q(collateral),
            'Health': h,
            'Actions': ' | '.join(actions) if actions else 'none'
        })
    
    return pd.DataFrame(rows)

def scenario8_multi_step_paths():
    """Scenario 8: Complex multi-step price paths"""
    paths = [
        {
            'name': 'BearMarket',
            'flow_prices': [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3],
            'yield_prices': [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7]  # Already monotonic
        },
        {
            'name': 'BullMarket',
            'flow_prices': [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
            # Fixed: yield prices must be monotonic non-decreasing
            'yield_prices': [1.0, 1.0, 1.05, 1.05, 1.1, 1.1, 1.15, 1.2]
        },
        {
            'name': 'Sideways',
            'flow_prices': [1.0, 1.1, 0.9, 1.05, 0.95, 1.02, 0.98, 1.0],
            # Fixed: yield prices must be monotonic non-decreasing
            'yield_prices': [1.0, 1.05, 1.05, 1.1, 1.1, 1.15, 1.15, 1.2]
        },
        {
            'name': 'Crisis',
            'flow_prices': [1.0, 0.5, 0.2, 0.1, 0.15, 0.3, 0.7, 1.2],
            # Fixed: yield prices must be monotonic non-decreasing
            'yield_prices': [1.0, 2.0, 5.0, 10.0, 10.0, 10.0, 10.0, 10.0]
        }
    ]
    
    all_rows = []
    
    for path in paths:
        debt = INIT_DEBT
        y_units = INIT_YIELD_UNITS
        flow_units = INIT_FLOW
        
        for step, (fp, yp) in enumerate(zip(path['flow_prices'], path['yield_prices'])):
            fp = Decimal(str(fp))
            yp = Decimal(str(yp))
            
            actions = []
            collateral = flow_units * fp
            
            # Auto-balancer
            if y_units * yp > debt * Decimal('1.05'):
                y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
                if fp > 0 and sold > 0:
                    flow_bought = moet_proceeds / fp
                    flow_units += flow_bought
                    collateral = flow_units * fp
                    actions.append(f"Sold {q(sold)} YIELD for {q(moet_proceeds)} MOET, bought {q(flow_bought)} FLOW")
            
            # Auto-borrow
            if collateral > 0:
                debt, y_units, act = borrow_or_repay_to_target(
                    collateral, debt, y_units, yp, instant=True, conditional=True
                )
                if act:
                    actions.append(act)
            
            h = health(collateral, debt) if debt > 0 else Decimal('999.999999999')
            
            all_rows.append({
                'PathName': path['name'],
                'Step': step,
                'FlowPrice': q(fp),
                'YieldPrice': q(yp),
                'Debt': q(debt),
                'YieldUnits': q(y_units),
                'FlowUnits': q(flow_units),
                'Collateral': q(collateral),
                'Health': h,
                'Actions': ' | '.join(actions) if actions else 'none'
            })
    
    return pd.DataFrame(all_rows)

def scenario9_random_walks():
    """Scenario 9: Random walk simulations for fuzzy testing"""
    random.seed(42)  # For reproducibility
    rows = []
    
    # Generate 5 random walks
    for walk_id in range(5):
        debt = INIT_DEBT
        y_units = INIT_YIELD_UNITS
        flow_units = INIT_FLOW
        
        flow_price = Decimal('1.0')
        yield_price = Decimal('1.0')
        
        for step in range(10):
            # Random walk with bounded volatility
            flow_change = Decimal(str(random.uniform(-0.2, 0.2)))
            # Yield can only increase or stay same (monotonic non-decreasing)
            yield_change = Decimal(str(random.uniform(0, 0.15)))  # Only positive changes
            
            flow_price = q(max(Decimal('0.1'), flow_price * (ONE + flow_change)))
            yield_price = q(max(Decimal('0.1'), yield_price * (ONE + yield_change)))
            
            actions = []
            collateral = flow_units * flow_price
            
            # Auto-balancer
            if y_units * yield_price > debt * Decimal('1.05'):
                y_units, moet_proceeds, sold = sell_to_debt(y_units, yield_price, debt)
                if flow_price > 0 and sold > 0:
                    flow_bought = moet_proceeds / flow_price
                    flow_units += flow_bought
                    collateral = flow_units * flow_price
                    actions.append(f"Sold {q(sold)} YIELD for {q(moet_proceeds)} MOET, bought {q(flow_bought)} FLOW")
            
            # Auto-borrow
            if collateral > 0:
                debt, y_units, act = borrow_or_repay_to_target(
                    collateral, debt, y_units, yield_price, instant=True, conditional=True
                )
                if act:
                    actions.append(act)
            
            h = health(collateral, debt) if debt > 0 else Decimal('999.999999999')
            
            rows.append({
                'WalkID': walk_id,
                'Step': step,
                'FlowPrice': flow_price,
                'YieldPrice': yield_price,
                'Debt': q(debt),
                'YieldUnits': q(y_units),
                'FlowUnits': q(flow_units),
                'Collateral': q(collateral),
                'Health': h,
                'Actions': ' | '.join(actions) if actions else 'none'
            })
    
    return pd.DataFrame(rows)

def scenario10_conditional_mode():
    """Scenario 10: Conditional mode (only rebalance when outside MIN_H/MAX_H)"""
    rows = []
    debt = INIT_DEBT
    y_units = INIT_YIELD_UNITS
    flow_units = INIT_FLOW
    
    # Test conditional thresholds
    flow_prices = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]
    yield_price = Decimal('1.2')  # Keep yield constant to focus on conditional logic
    
    for i, fp in enumerate(flow_prices):
        fp = Decimal(str(fp))
        actions = []
        collateral = flow_units * fp
        
        # Auto-balancer (still active in conditional mode)
        if y_units * yield_price > debt * Decimal('1.05'):
            y_units, moet_proceeds, sold = sell_to_debt(y_units, yield_price, debt)
            if fp > 0 and sold > 0:
                flow_bought = moet_proceeds / fp
                flow_units += flow_bought
                collateral = flow_units * fp
                actions.append(f"Sold {q(sold)} YIELD for {q(moet_proceeds)} MOET, bought {q(flow_bought)} FLOW")
        
        # Conditional auto-borrow (only if health outside 1.1-1.5)
        h_before = health(collateral, debt)
        debt, y_units, act = borrow_or_repay_to_target(
            collateral, debt, y_units, yield_price, instant=False, conditional=True
        )
        if act:
            actions.append(act)
        
        h_after = health(collateral, debt)
        
        rows.append({
            'Step': i,
            'FlowPrice': q(fp),
            'YieldPrice': yield_price,
            'Debt': q(debt),
            'YieldUnits': q(y_units),
            'FlowUnits': q(flow_units),
            'Collateral': q(collateral),
            'HealthBefore': h_before,
            'HealthAfter': h_after,
            'InBand': 'Yes' if MIN_H <= h_before <= MAX_H else 'No',
            'Actions': ' | '.join(actions) if actions else 'none'
        })
    
    return pd.DataFrame(rows)

# ---- Main --------------------------------------------------------------
def main():
    out = Path.cwd()
    
    print("Generating all scenarios (1-10) for fuzzy testing...")
    
    # Generate original scenarios (1-4) for comparison
    save_csv(scenario1_flow(), out/'Scenario1_FLOW_extended.csv')
    print("✓ Scenario1_FLOW_extended.csv")
    
    save_csv(scenario2('instant'), out/'Scenario2_Instant_extended.csv')
    print("✓ Scenario2_Instant_extended.csv")
    

    
    for name, df in scenario3_paths():
        save_csv(df, out/f'Scenario3_{name}_extended.csv')
        print(f"✓ Scenario3_{name}_extended.csv")
    
    save_csv(scenario4_scaling(), out/'Scenario4_Scaling_extended.csv')
    print("✓ Scenario4_Scaling_extended.csv")
    
    # Generate extended scenarios (5-10)
    save_csv(scenario5_volatile_markets(), out/'Scenario5_VolatileMarkets.csv')
    print("✓ Scenario5_VolatileMarkets.csv")
    
    save_csv(scenario6_gradual_trends(), out/'Scenario6_GradualTrends.csv')
    print("✓ Scenario6_GradualTrends.csv")
    
    save_csv(scenario7_edge_cases(), out/'Scenario7_EdgeCases.csv')
    print("✓ Scenario7_EdgeCases.csv")
    
    save_csv(scenario8_multi_step_paths(), out/'Scenario8_MultiStepPaths.csv')
    print("✓ Scenario8_MultiStepPaths.csv")
    
    save_csv(scenario9_random_walks(), out/'Scenario9_RandomWalks.csv')
    print("✓ Scenario9_RandomWalks.csv")
    
    save_csv(scenario10_conditional_mode(), out/'Scenario10_ConditionalMode.csv')
    print("✓ Scenario10_ConditionalMode.csv")
    
    print("\nAll scenarios (1-10) generated successfully!")

if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""
Tidal Protocol Simulator - Implements the unified test suite for instant-borrow and monotonic-yield.
Generates CSVs for 10 scenarios with 9-decimal precision.
"""

import pandas as pd
from decimal import Decimal, getcontext, ROUND_HALF_UP
from pathlib import Path
import math
import random

# Precision setup
getcontext().prec = 28
DP = Decimal('0.000000001')  # 9-dp quantiser

def q(x):
    """Quantise to 9 dp."""
    return Decimal(x).quantize(DP, rounding=ROUND_HALF_UP)

# Constants
CF = Decimal('0.8')
TARGET_H = Decimal('1.3')
MIN_H = Decimal('1.1')
MAX_H = Decimal('1.5')

# Initial baseline
INIT_FLOW_HOLDINGS = Decimal('1000')
INIT_FLOW_PRICE = Decimal('1.0')
INIT_COLLATERAL = INIT_FLOW_HOLDINGS * INIT_FLOW_PRICE
INIT_DEBT = q(INIT_COLLATERAL * CF / TARGET_H)
INIT_YIELD_UNITS = INIT_DEBT

ONE = Decimal('1')

# Helper functions
def health(collateral: Decimal, debt: Decimal) -> Decimal:
    return q((collateral * CF) / debt) if debt > 0 else Decimal('999.999999999')

def simulate_tick(flow_price: Decimal, yield_price: Decimal,
                  flow_holdings: Decimal, debt: Decimal, yield_units: Decimal) -> tuple:
    """
    Simulate one price tick according to the workflow.
    Returns updated (flow_holdings, debt, yield_units, actions, health_before, health_after)
    """
    # 1. Mark to market
    collateral_value = q(flow_holdings * flow_price)
    debt_value = debt  # MOET is stable at 1.0
    yield_value = q(yield_units * yield_price)
    health_before = health(collateral_value, debt_value)

    actions = []

    # 2. Auto-Balancer
    if yield_value > debt_value * Decimal('1.05'):
        excess_value = q(yield_value - debt_value)
        sell_units = q(excess_value / yield_price)
        yield_units = q(yield_units - sell_units)
        # Buy FLOW with proceeds (assuming proceeds = excess_value in MOET)
        if flow_price > 0:
            flow_bought = q(excess_value / flow_price)
            flow_holdings = q(flow_holdings + flow_bought)
            collateral_value = q(flow_holdings * flow_price)
        actions.append(f"Bal sell {sell_units}")

    # 3. Auto-Borrow
    # Always adjust to target health 1.3
    target_debt = q(collateral_value * CF / TARGET_H)
    delta = q(target_debt - debt_value)
    if delta > 0:  # borrow
        debt_value = q(debt_value + delta)
        buy_units = q(delta / yield_price)
        yield_units = q(yield_units + buy_units)
        actions.append(f"Borrow {delta}")
    elif delta < 0:  # repay
        repay_value = q(-delta)
        repay_units = q(repay_value / yield_price)
        yield_units = q(yield_units - repay_units)
        debt_value = q(debt_value - repay_value)
        actions.append(f"Repay {repay_value}")

    # 4. Final health
    health_after = health(collateral_value, debt_value)

    action_str = " | ".join(actions) if actions else "none"

    return flow_holdings, debt_value, yield_units, action_str, health_before, health_after, collateral_value

def save_csv(df: pd.DataFrame, filepath: Path):
    """Save DataFrame to CSV with 9-decimal precision."""
    df = df.map(lambda x: q(x) if isinstance(x, (Decimal, float, int)) else x)
    df = df.map(lambda x: float(x) if isinstance(x, Decimal) else x)
    df.to_csv(filepath, index=False, float_format='%.9f')

# Scenario Generators

def scenario1_flow_grid():
    """1. FLOW grid – isolated FLOW moves, path-independent."""
    flow_prices = [Decimal('0.5'), Decimal('0.8'), Decimal('1.0'), Decimal('1.2'),
                   Decimal('1.5'), Decimal('2.0'), Decimal('3.0'), Decimal('5.0')]
    rows = []
    for fp in flow_prices:
        flow_holdings = INIT_FLOW_HOLDINGS
        debt = INIT_DEBT
        yield_units = INIT_YIELD_UNITS
        yp = ONE  # Fixed yield price for isolation

        flow_holdings, debt, yield_units, action, h_before, h_after, coll = simulate_tick(
            fp, yp, flow_holdings, debt, yield_units
        )

        rows.append({
            'FlowPrice': fp,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'HealthBefore': h_before,
            'HealthAfter': h_after,
            'Action': action
        })
    return pd.DataFrame(rows)

def scenario2_yield_grid():
    """2. YIELD grid – instant – always borrow to 1.3."""
    yield_prices = [Decimal('1.0'), Decimal('1.1'), Decimal('1.2'), Decimal('1.3'),
                    Decimal('1.5'), Decimal('2.0'), Decimal('3.0')]
    flow_holdings = INIT_FLOW_HOLDINGS
    debt = INIT_DEBT
    yield_units = INIT_YIELD_UNITS
    fp = ONE  # Fixed flow price
    rows = []

    for step, yp in enumerate(yield_prices):
        flow_holdings, debt, yield_units, action, h_before, h_after, coll = simulate_tick(
            fp, yp, flow_holdings, debt, yield_units
        )
        rows.append({
            'Step': step,
            'YieldPrice': yp,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'HealthBefore': h_before,
            'HealthAfter': h_after,
            'Action': action
        })
    return pd.DataFrame(rows)

def scenario3_combined_paths():
    """4. Combined paths A–D – FLOW jump then YIELD jump."""
    paths = [
        ('A', Decimal('0.8'), Decimal('1.2')),
        ('B', Decimal('1.5'), Decimal('1.3')),
        ('C', Decimal('2.0'), Decimal('2.0')),
        ('D', Decimal('0.5'), Decimal('1.5'))
    ]
    all_dfs = []
    for name, fp, yp in paths:
        rows = []
        # Initial
        flow_holdings = INIT_FLOW_HOLDINGS
        debt = INIT_DEBT
        yield_units = INIT_YIELD_UNITS
        init_coll = q(flow_holdings * INIT_FLOW_PRICE)
        rows.append({
            'Path': name,
            'Step': 0,
            'Label': 'start',
            'FlowPrice': INIT_FLOW_PRICE,
            'YieldPrice': ONE,
            'Collateral': init_coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'Health': health(init_coll, debt),
            'Action': 'none'
        })

        # FLOW jump (instant mode)
        flow_holdings, debt, yield_units, action, _, _, coll = simulate_tick(
            fp, ONE, flow_holdings, debt, yield_units
        )
        rows.append({
            'Path': name,
            'Step': 1,
            'Label': 'after FLOW',
            'FlowPrice': fp,
            'YieldPrice': ONE,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'Health': health(coll, debt),
            'Action': action
        })

        # YIELD jump (instant mode)
        flow_holdings, debt, yield_units, action, _, _, coll = simulate_tick(
            fp, yp, flow_holdings, debt, yield_units
        )
        rows.append({
            'Path': name,
            'Step': 2,
            'Label': 'after YIELD',
            'FlowPrice': fp,
            'YieldPrice': yp,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'Health': health(coll, debt),
            'Action': action
        })

        all_dfs.append((name, pd.DataFrame(rows)))
    return all_dfs

def scenario4_scaling():
    """5. Scaling – deposit sizes 100 → 10 000 FLOW."""
    deposits = [Decimal('100'), Decimal('500'), Decimal('1000'),
                Decimal('5000'), Decimal('10000')]
    rows = []
    for dep in deposits:
        flow_holdings = dep
        coll = q(dep * ONE)
        debt = q(coll * CF / TARGET_H)
        yield_units = debt
        rows.append({
            'InitialFLOW': dep,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'Health': TARGET_H
        })
    return pd.DataFrame(rows)

def scenario5_volatile_whiplash():
    """5. Volatile Whiplash – 10-tick sequence: FLOW and monotonic-rising YIELD alternate sharp moves."""
    flow_prices = [Decimal('1.0'), Decimal('1.8'), Decimal('0.6'), Decimal('2.2'), Decimal('0.7'), Decimal('1.9'), Decimal('0.5'), Decimal('2.5'), Decimal('0.4'), Decimal('3.0')]
    yield_prices = [Decimal('1.0'), Decimal('1.2'), Decimal('1.5'), Decimal('1.7'), Decimal('1.9'), Decimal('2.1'), Decimal('2.3'), Decimal('2.5'), Decimal('2.8'), Decimal('3.0')]
    flow_holdings = INIT_FLOW_HOLDINGS
    debt = INIT_DEBT
    yield_units = INIT_YIELD_UNITS
    rows = []
    coll = q(flow_holdings * ONE)
    h = health(coll, debt)
    rows.append({
        'Step': 0,
        'FlowPrice': ONE,
        'YieldPrice': ONE,
        'Collateral': coll,
        'Debt': debt,
        'YieldUnits': yield_units,
        'HealthBefore': h,
        'HealthAfter': h,
        'Action': 'none'
    })
    for step in range(1, 11):
        fp = flow_prices[step-1]
        yp = yield_prices[step-1]
        flow_holdings, debt, yield_units, action, h_before, h_after, coll = simulate_tick(
            fp, yp, flow_holdings, debt, yield_units
        )
        rows.append({
            'Step': step,
            'FlowPrice': fp,
            'YieldPrice': yp,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'HealthBefore': h_before,
            'HealthAfter': h_after,
            'Action': action
        })
    return pd.DataFrame(rows)

def scenario6_gradual_trend():
    """6. Gradual Trend (Sine/Cosine Up-only) – 20 small ticks: FLOW oscillates (up/down); YIELD only ratchets up in 0.3%-style increments."""
    rows = []
    flow_holdings = INIT_FLOW_HOLDINGS
    debt = INIT_DEBT
    yield_units = INIT_YIELD_UNITS
    coll = q(flow_holdings * ONE)
    h = health(coll, debt)
    rows.append({
        'Step': 0,
        'FlowPrice': ONE,
        'YieldPrice': ONE,
        'Collateral': coll,
        'Debt': debt,
        'YieldUnits': yield_units,
        'HealthBefore': h,
        'HealthAfter': h,
        'Action': 'none'
    })
    for i in range(1, 21):
        fp = q(Decimal(1 + 0.05 * math.sin(2 * math.pi * i / 5)))
        yp = q(Decimal('1.0') * (Decimal('1.003') ** i))
        flow_holdings, debt, yield_units, action, h_before, h_after, coll = simulate_tick(
            fp, yp, flow_holdings, debt, yield_units
        )
        rows.append({
            'Step': i,
            'FlowPrice': fp,
            'YieldPrice': yp,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'HealthBefore': h_before,
            'HealthAfter': h_after,
            'Action': action
        })
    return pd.DataFrame(rows)

def scenario7_edge_cases():
    """7. Edge / Boundary Cases – each is a single tick."""
    tests = [
        ('VeryLowFlow', Decimal('0.01'), Decimal('1'), INIT_FLOW_HOLDINGS),
        ('VeryHighFlow', Decimal('100'), Decimal('1'), INIT_FLOW_HOLDINGS),
        ('VeryHighYield', Decimal('1'), Decimal('50'), INIT_FLOW_HOLDINGS),
        ('BothVeryLow', Decimal('0.05'), Decimal('0.02'), INIT_FLOW_HOLDINGS),
        ('MinimalPosition', Decimal('1'), Decimal('1'), Decimal('1')),
        ('LargePosition', Decimal('1'), Decimal('1'), Decimal('1000000')),
    ]
    rows = []
    for name, fp, yp, init_flow in tests:
        flow_holdings = init_flow
        initial_coll = q(init_flow * ONE)
        debt = q(initial_coll * CF / TARGET_H)
        yield_units = debt
        flow_holdings, debt, yield_units, action, h_before, h_after, coll = simulate_tick(
            fp, yp, flow_holdings, debt, yield_units
        )
        rows.append({
            'Test': name,
            'FlowPrice': fp,
            'YieldPrice': yp,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'HealthBefore': h_before,
            'HealthAfter': h_after,
            'Action': action
        })
    return pd.DataFrame(rows)

def scenario8_named_paths():
    """8. Multi-Step Named Paths – 8-tick macros with monotone-up YIELD."""
    paths = {
        'Bear': {
            'flow': [Decimal('1.0'), Decimal('0.95'), Decimal('0.9'), Decimal('0.85'), Decimal('0.8'), Decimal('0.75'), Decimal('0.7'), Decimal('0.65')],
            'yield': [Decimal('1.0'), Decimal('1.05'), Decimal('1.1'), Decimal('1.15'), Decimal('1.2'), Decimal('1.25'), Decimal('1.3'), Decimal('1.35')]
        },
        'Bull': {
            'flow': [Decimal('1.0'), Decimal('1.1'), Decimal('1.3'), Decimal('1.5'), Decimal('1.8'), Decimal('2.1'), Decimal('2.5'), Decimal('3.0')],
            'yield': [Decimal('1.0'), Decimal('1.01'), Decimal('1.02'), Decimal('1.03'), Decimal('1.04'), Decimal('1.05'), Decimal('1.06'), Decimal('1.07')]
        },
        'Sideways': {
            'flow': [Decimal('1.0'), Decimal('1.02'), Decimal('0.98'), Decimal('1.03'), Decimal('0.97'), Decimal('1.01'), Decimal('0.99'), Decimal('1.0')],
            'yield': [Decimal('1.0'), Decimal('1.005'), Decimal('1.01'), Decimal('1.015'), Decimal('1.02'), Decimal('1.025'), Decimal('1.03'), Decimal('1.035')]
        },
        'Crisis': {
            'flow': [Decimal('1.0'), Decimal('0.5'), Decimal('0.4'), Decimal('0.6'), Decimal('0.8'), Decimal('1.2'), Decimal('1.5'), Decimal('1.8')],
            'yield': [Decimal('1.0'), Decimal('1.5'), Decimal('2.0'), Decimal('2.0'), Decimal('2.0'), Decimal('2.0'), Decimal('2.0'), Decimal('2.0')]
        }
    }
    all_dfs = []
    for name, data in paths.items():
        flow_prices = data['flow']
        yield_prices = data['yield']
        flow_holdings = INIT_FLOW_HOLDINGS
        debt = INIT_DEBT
        yield_units = INIT_YIELD_UNITS
        rows = []
        coll = q(flow_holdings * ONE)
        h = health(coll, debt)
        rows.append({
            'Path': name,
            'Step': 0,
            'FlowPrice': ONE,
            'YieldPrice': ONE,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'HealthBefore': h,
            'HealthAfter': h,
            'Action': 'none'
        })
        for step in range(1, 9):
            fp = q(flow_prices[step - 1])
            yp = q(yield_prices[step - 1])
            flow_holdings, debt, yield_units, action, h_before, h_after, coll = simulate_tick(
                fp, yp, flow_holdings, debt, yield_units
            )
            rows.append({
                'Path': name,
                'Step': step,
                'FlowPrice': fp,
                'YieldPrice': yp,
                'Collateral': coll,
                'Debt': debt,
                'YieldUnits': yield_units,
                'HealthBefore': h_before,
                'HealthAfter': h_after,
                'Action': action
            })
        all_dfs.append((name, pd.DataFrame(rows)))
    return all_dfs

def scenario9_bounded_random_walks():
    """9. Bounded Random Walks – 5 random walks × 10 ticks."""
    random.seed(42)
    num_walks = 5
    num_ticks = 10
    all_rows = []
    for walk in range(num_walks):
        flow_price = Decimal('1.0')
        yield_price = Decimal('1.0')
        flow_holdings = INIT_FLOW_HOLDINGS
        debt = INIT_DEBT
        yield_units = INIT_YIELD_UNITS
        rows = []
        coll = q(flow_holdings * flow_price)
        h = health(coll, debt)
        rows.append({
            'Walk': walk + 1,
            'Step': 0,
            'FlowPrice': flow_price,
            'YieldPrice': yield_price,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'HealthBefore': h,
            'HealthAfter': h,
            'Action': 'none'
        })
        for step in range(1, num_ticks + 1):
            flow_change = Decimal(random.uniform(-0.2, 0.2))
            yield_change = Decimal(random.uniform(0, 0.15))
            flow_price = max(Decimal('0.1'), flow_price * (1 + flow_change))
            yield_price = yield_price * (1 + yield_change)
            flow_price = q(flow_price)
            yield_price = q(yield_price)
            flow_holdings, debt, yield_units, action, h_before, h_after, coll = simulate_tick(
                flow_price, yield_price, flow_holdings, debt, yield_units
            )
            rows.append({
                'Walk': walk + 1,
                'Step': step,
                'FlowPrice': flow_price,
                'YieldPrice': yield_price,
                'Collateral': coll,
                'Debt': debt,
                'YieldUnits': yield_units,
                'HealthBefore': h_before,
                'HealthAfter': h_after,
                'Action': action
            })
        all_rows.extend(rows)
    return pd.DataFrame(all_rows)

def scenario10_extreme_shocks():
    """10. Extreme One-Tick Shocks – single tick each."""
    tests = [
        ('FlashCrash', Decimal('0.3'), Decimal('1')),
        ('Rebound', Decimal('4.0'), Decimal('1')),
        ('YieldHyperInflate', Decimal('1'), Decimal('5')),
        ('MixedShock', Decimal('0.4'), Decimal('2.2')),
    ]
    rows = []
    for name, fp, yp in tests:
        flow_holdings = INIT_FLOW_HOLDINGS
        debt = INIT_DEBT
        yield_units = INIT_YIELD_UNITS
        flow_holdings, debt, yield_units, action, h_before, h_after, coll = simulate_tick(
            fp, yp, flow_holdings, debt, yield_units
        )
        rows.append({
            'Test': name,
            'FlowPrice': fp,
            'YieldPrice': yp,
            'Collateral': coll,
            'Debt': debt,
            'YieldUnits': yield_units,
            'HealthBefore': h_before,
            'HealthAfter': h_after,
            'Action': action
        })
    return pd.DataFrame(rows)

def main():
    out = Path.cwd()
    print("Generating 10 scenarios...")
    save_csv(scenario1_flow_grid(), out / 'Scenario1_FLOW_Price_Grid.csv')
    save_csv(scenario2_yield_grid(), out / 'Scenario2_YIELD_Price_Grid.csv')
    for name, df in scenario3_combined_paths():
        save_csv(df, out / f'Scenario3_Two_Step_Path_{name}.csv')
    save_csv(scenario4_scaling(), out / 'Scenario4_Scaling_Baselines.csv')
    save_csv(scenario5_volatile_whiplash(), out / 'Scenario5_Volatile_Whiplash.csv')
    save_csv(scenario6_gradual_trend(), out / 'Scenario6_Gradual_Trend.csv')
    save_csv(scenario7_edge_cases(), out / 'Scenario7_Edge_Boundary_Cases.csv')
    for name, df in scenario8_named_paths():
        save_csv(df, out / f'Scenario8_Multi_Step_Path_{name}.csv')
    save_csv(scenario9_bounded_random_walks(), out / 'Scenario9_Bounded_Random_Walks.csv')
    save_csv(scenario10_extreme_shocks(), out / 'Scenario10_Extreme_One_Tick_Shocks.csv')
    print("✓ All CSVs generated.")

if __name__ == "__main__":
    main() 
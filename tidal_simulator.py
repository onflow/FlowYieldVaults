
"""tidal_simulator.py
Generates the unified fuzzy-testing CSVs for Tidal Protocol.

Rules enforced across scenarios:
- Auto-Borrow always fires per tick (target health = 1.3)
- YIELD price is monotonic non-decreasing within a path

Run: python tidal_simulator.py
"""

import pandas as pd
from decimal import Decimal, getcontext, ROUND_HALF_UP
from pathlib import Path

# ---- Precision ---------------------------------------------------------
getcontext().prec = 28            # plenty of headroom
DP = Decimal('0.000000001')       # 9‑dp quantiser

def q(x: Decimal | float | str) -> Decimal:
    return Decimal(x).quantize(DP, rounding=ROUND_HALF_UP)

# ---- Constants ---------------------------------------------------------
CF        = Decimal('0.8')
TARGET_H  = Decimal('1.3')
MIN_H     = Decimal('1.1')
MAX_H     = Decimal('1.5')

# Initial baseline
INIT_FLOW_PRICE = Decimal('1.0')
INIT_FLOW = Decimal('1000')
INIT_COLLATERAL = INIT_FLOW * INIT_FLOW_PRICE
INIT_DEBT = q(INIT_COLLATERAL * CF / TARGET_H)
INIT_YIELD_UNITS = INIT_DEBT
ONE = Decimal('1')

# ---- Helper functions --------------------------------------------------
def health(collateral: Decimal, debt: Decimal) -> Decimal:
    return q((collateral * CF) / debt) if debt > 0 else Decimal('999.999999999')

def sell_to_debt(y_units: Decimal, y_price: Decimal, debt: Decimal):
    """Returns (new_y_units, moet_proceeds, sold_units)"""
    y_value = y_units * y_price
    if y_value <= debt:
        return y_units, Decimal('0'), Decimal('0')
    excess_value = y_value - debt
    sell_units = q(excess_value / y_price)
    return (y_units - sell_units, q(excess_value), sell_units)

def borrow_or_repay_to_target(collateral: Decimal, debt: Decimal,
                              y_units: Decimal, y_price: Decimal,
                              instant: bool, conditional: bool):
    """Adjust debt to reach target health.
    Always acts when `instant` is True; otherwise only when outside [MIN_H, MAX_H]."""
    h = health(collateral, debt)
    action = None
    if instant or h > MAX_H or h < MIN_H:
        target_debt = q(collateral * CF / TARGET_H)
        delta = q(target_debt - debt)
        if delta > 0:          # borrow
            debt += delta
            y_units += q(delta / y_price)
            action = f"Borrow {delta}"
        elif delta < 0:        # repay
            repay = -delta
            y_units -= q(repay / y_price)
            debt -= repay
            action = f"Repay {repay}"
    return debt, y_units, action

def save_csv(df: pd.DataFrame, filepath: Path):
    """Save DataFrame to CSV with 9-decimal precision for numerics."""
    df = df.map(lambda x: q(x) if isinstance(x, (Decimal, int, float)) else x)
    df = df.map(lambda x: float(x) if isinstance(x, Decimal) else x)
    df.to_csv(filepath, index=False, float_format='%.9f')

# ---- Scenario builders -------------------------------------------------
def scenario1_flow():
    """FLOW price grid; YIELD fixed at 1."""
    rows = []
    for p in map(Decimal, '0.5 0.8 1.0 1.2 1.5 2.0 3.0 5.0'.split()):
        collateral = q(INIT_FLOW * p)
        be = q(collateral * CF)
        debt_before = INIT_DEBT
        h_before = health(collateral, debt_before)
        action = "none"
        debt_after = debt_before
        y_after = INIT_YIELD_UNITS
        if h_before < MIN_H:
            target = q(be / TARGET_H)
            repay = q(debt_before - target)
            debt_after = target
            y_after -= repay
            action = f"Repay {repay}"
        elif h_before > MAX_H:
            target = q(be / TARGET_H)
            borrow = q(target - debt_before)
            debt_after = target
            y_after += borrow
            action = f"Borrow {borrow}"
        h_after = health(collateral, debt_after)
        rows.append(dict(
            FlowPrice=p, Collateral=collateral, BorrowEligible=be,
            DebtBefore=debt_before, HealthBefore=h_before,
            Action=action, DebtAfter=debt_after,
            YieldAfter=y_after, HealthAfter=h_after
        ))
    return pd.DataFrame(rows)

def scenario2(path_mode: str):
    """YIELD path with auto-balancer; FLOW = 1. path_mode: 'instant' only used."""
    instant = path_mode == 'instant'
    debt = INIT_DEBT
    y_units = INIT_YIELD_UNITS
    coll_units = INIT_FLOW  # track FLOW units as balancer may buy FLOW
    rows = []
    for yp in map(Decimal, '1.0 1.1 1.2 1.3 1.5 2.0 3.0'.split()):
        fp = ONE
        collateral = q(coll_units * fp)
        actions = []
        # Auto-balancer: sell YIELD if > 1.05×Debt and buy FLOW
        if y_units * yp > debt * Decimal('1.05'):
            y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
            if sold > 0:
                flow_bought = q(moet_proceeds / fp)
                coll_units += flow_bought
                collateral = q(coll_units * fp)
                actions.append(f"Bal sell {sold}")
        # Auto-borrow to target health
        debt, y_units, act = borrow_or_repay_to_target(collateral, debt, y_units, yp,
                                                       instant=instant, conditional=True)
        if act:
            actions.append(act)
        rows.append(dict(
            YieldPrice=yp, Debt=debt, YieldUnits=y_units,
            Collateral=collateral, Health=health(collateral, debt),
            Actions=" | ".join(actions) if actions else "none"
        ))
    return pd.DataFrame(rows)

def scenario3_paths():
    """Two-step combined paths (A-D)."""
    def build(name: str, fp: Decimal, yp: Decimal):
        debt = INIT_DEBT
        y = INIT_YIELD_UNITS
        flow_units = INIT_FLOW
        rows = []
        # Step 0: initial
        coll = q(flow_units * ONE)
        rows.append(dict(Step=0, Label='start', FlowPrice=ONE, YieldPrice=ONE,
                         Debt=debt, YieldUnits=y, Collateral=coll,
                         Health=health(coll, debt), Action='none'))
        # Step 1: FLOW move
        coll = q(flow_units * fp)
        debt, y, act = borrow_or_repay_to_target(coll, debt, y, ONE, instant=True, conditional=True)
        rows.append(dict(Step=1, Label='after FLOW', FlowPrice=fp, YieldPrice=ONE,
                         Debt=debt, YieldUnits=y, Collateral=coll,
                         Health=health(coll, debt), Action=act or 'none'))
        # Step 2: YIELD move + balancer
        actions = []
        if y * yp > debt * Decimal('1.05'):
            y, moet_proceeds, sold = sell_to_debt(y, yp, debt)
            if sold > 0:
                flow_bought = q(moet_proceeds / fp)
                flow_units += flow_bought
                coll = q(flow_units * fp)
                actions.append(f"Bal sell {sold}")
        debt, y, act2 = borrow_or_repay_to_target(coll, debt, y, yp, instant=True, conditional=True)
        if act2:
            actions.append(act2)
        rows.append(dict(Step=2, Label='after YIELD', FlowPrice=fp, YieldPrice=yp,
                         Debt=debt, YieldUnits=y, Collateral=coll,
                         Health=health(coll, debt), Action=" | ".join(actions) if actions else 'none'))
        return name, pd.DataFrame(rows)

    specs = [
        ('Path_A_precise', Decimal('0.8'), Decimal('1.2')),
        ('Path_B_precise', Decimal('1.5'), Decimal('1.3')),
        ('Path_C_precise', Decimal('2.0'), Decimal('2.0')),
        ('Path_D_precise', Decimal('0.5'), Decimal('1.5'))
    ]
    return [build(n, fp, yp) for n, fp, yp in specs]

def scenario4_scaling():
    """Initial FLOW deposits scaling table at price=1."""
    rows = []
    for dep in map(Decimal, '100 500 1000 5000 10000'.split()):
        debt = q(dep * CF / TARGET_H)
        rows.append(dict(InitialFLOW=dep, Collateral=dep,
                         Debt=debt, YieldUnits=debt, Health=Decimal('1.3')))
    return pd.DataFrame(rows)

def scenario5_volatile_markets():
    rows = []
    debt = INIT_DEBT
    y_units = INIT_YIELD_UNITS
    flow_units = INIT_FLOW
    flow_prices = [Decimal('1.0'), Decimal('1.8'), Decimal('0.6'), Decimal('2.2'), Decimal('0.4'), Decimal('3.0'), Decimal('1.0'), Decimal('0.2'), Decimal('4.0'), Decimal('1.5')]
    # Monotone non-decreasing YIELD path
    yield_prices = [Decimal('1.0'), Decimal('1.2'), Decimal('1.5'), Decimal('1.5'), Decimal('2.5'), Decimal('2.5'), Decimal('3.5'), Decimal('3.5'), Decimal('4.0'), Decimal('4.0')]
    for i, (fp, yp) in enumerate(zip(flow_prices, yield_prices)):
        actions = []
        collateral = q(flow_units * fp)
        if y_units * yp > debt * Decimal('1.05'):
            y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
            if fp > 0 and sold > 0:
                flow_bought = q(moet_proceeds / fp)
                flow_units += flow_bought
                collateral = q(flow_units * fp)
                actions.append(f"Bal sell {sold}")
        debt, y_units, act = borrow_or_repay_to_target(collateral, debt, y_units, yp, instant=True, conditional=True)
        if act:
            actions.append(act)
        rows.append(dict(Step=i, FlowPrice=fp, YieldPrice=yp, Debt=debt, YieldUnits=y_units,
                         FlowUnits=q(flow_units), Collateral=collateral, Health=health(collateral, debt),
                         Actions=' | '.join(actions) if actions else 'none'))
    return pd.DataFrame(rows)

def scenario6_gradual_trends():
    import math
    rows = []
    debt = INIT_DEBT
    y_units = INIT_YIELD_UNITS
    flow_units = INIT_FLOW
    for i in range(20):
        fp = q(Decimal(str(1 + 0.5 * math.sin(i * math.pi / 10))))
        yp = q(Decimal(str(1 + 0.02 * i)))  # strictly increasing
        actions = []
        collateral = q(flow_units * fp)
        if y_units * yp > debt * Decimal('1.05'):
            y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
            if fp > 0 and sold > 0:
                flow_bought = q(moet_proceeds / fp)
                flow_units += flow_bought
                collateral = q(flow_units * fp)
                actions.append(f"Bal sell {sold}")
        debt, y_units, act = borrow_or_repay_to_target(collateral, debt, y_units, yp, instant=True, conditional=True)
        if act:
            actions.append(act)
        rows.append(dict(Step=i, FlowPrice=fp, YieldPrice=yp, Debt=debt, YieldUnits=y_units,
                         FlowUnits=q(flow_units), Collateral=collateral, Health=health(collateral, debt),
                         Actions=' | '.join(actions) if actions else 'none'))
    return pd.DataFrame(rows)

def scenario7_edge_cases():
    tests = [
        ('VeryLowFlow', INIT_FLOW, Decimal('0.01'), Decimal('1.0')),
        ('VeryHighFlow', INIT_FLOW, Decimal('100.0'), Decimal('1.0')),
        ('VeryHighYield', INIT_FLOW, Decimal('1.0'), Decimal('50.0')),
        ('BothVeryLow', INIT_FLOW, Decimal('0.05'), Decimal('0.02')),
        ('MinimalPosition', Decimal('1'), Decimal('1.0'), Decimal('1.0')),
        ('LargePosition', Decimal('1000000'), Decimal('1.0'), Decimal('1.0')),
    ]
    rows = []
    for name, init_flow_units, fp, yp in tests:
        flow_units = init_flow_units
        debt = q(flow_units * CF / TARGET_H)
        y_units = debt
        collateral = q(flow_units * fp)
        actions = []
        if y_units * yp > debt * Decimal('1.05'):
            y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
            if fp > 0 and sold > 0:
                flow_bought = q(moet_proceeds / fp)
                flow_units += flow_bought
                collateral = q(flow_units * fp)
                actions.append(f"Bal sell {sold}")
        if collateral > 0:
            debt, y_units, act = borrow_or_repay_to_target(collateral, debt, y_units, yp, instant=True, conditional=True)
            if act:
                actions.append(act)
        rows.append(dict(TestCase=name, InitialFlow=init_flow_units, FlowPrice=fp, YieldPrice=yp,
                          Debt=debt, YieldUnits=y_units, FlowUnits=q(flow_units), Collateral=collateral,
                          Health=health(collateral, debt), Actions=' | '.join(actions) if actions else 'none'))
    return pd.DataFrame(rows)

def scenario7_multi_step_paths_split():
    paths = [
        ('Bear',    [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3], [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7]),
        ('Bull',    [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0], [1.0, 1.0, 1.05, 1.05, 1.1, 1.1, 1.15, 1.2]),
        ('Sideways',[1.0, 1.1, 0.9, 1.05, 0.95, 1.02, 0.98, 1.0], [1.0, 1.05, 1.05, 1.1, 1.1, 1.15, 1.15, 1.2]),
        ('Crisis',  [1.0, 0.5, 0.2, 0.1, 0.15, 0.3, 0.7, 1.2], [1.0, 2.0, 5.0, 10.0, 10.0, 10.0, 10.0, 10.0]),
    ]
    per_path = []
    for name, fp_list, yp_list in paths:
        debt = INIT_DEBT
        y_units = INIT_YIELD_UNITS
        flow_units = INIT_FLOW
        rows = []
        for step, (fpv, ypv) in enumerate(zip(fp_list, yp_list)):
            fp = q(Decimal(str(fpv)))
            yp = q(Decimal(str(ypv)))
            actions = []
            collateral = q(flow_units * fp)
            if y_units * yp > debt * Decimal('1.05'):
                y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
                if fp > 0 and sold > 0:
                    flow_bought = q(moet_proceeds / fp)
                    flow_units += flow_bought
                    collateral = q(flow_units * fp)
                    actions.append(f"Bal sell {sold}")
            debt, y_units, act = borrow_or_repay_to_target(collateral, debt, y_units, yp, instant=True, conditional=True)
            if act:
                actions.append(act)
            rows.append(dict(Step=step, FlowPrice=fp, YieldPrice=yp, Debt=debt,
                             YieldUnits=y_units, FlowUnits=q(flow_units), Collateral=collateral,
                             Health=health(collateral, debt), Actions=' | '.join(actions) if actions else 'none'))
        per_path.append((name, pd.DataFrame(rows)))
    return per_path

def scenario9_random_walks():
    import random
    random.seed(42)
    rows = []
    for walk_id in range(5):
        debt = INIT_DEBT
        y_units = INIT_YIELD_UNITS
        flow_units = INIT_FLOW
        fp = ONE
        yp = ONE
        for step in range(10):
            # FLOW bounded ±20%; YIELD 0..+15% monotone
            fp = q(max(Decimal('0.1'), fp * (ONE + Decimal(str(random.uniform(-0.2, 0.2))))))
            yp = q(max(yp, yp * (ONE + Decimal(str(random.uniform(0, 0.15))))))
            actions = []
            collateral = q(flow_units * fp)
            if y_units * yp > debt * Decimal('1.05'):
                y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
                if fp > 0 and sold > 0:
                    flow_bought = q(moet_proceeds / fp)
                    flow_units += flow_bought
                    collateral = q(flow_units * fp)
                    actions.append(f"Bal sell {sold}")
            debt, y_units, act = borrow_or_repay_to_target(collateral, debt, y_units, yp, instant=True, conditional=True)
            if act:
                actions.append(act)
            rows.append(dict(WalkID=walk_id, Step=step, FlowPrice=fp, YieldPrice=yp, Debt=debt,
                             YieldUnits=y_units, FlowUnits=q(flow_units), Collateral=collateral,
                             Health=health(collateral, debt), Actions=' | '.join(actions) if actions else 'none'))
    return pd.DataFrame(rows)

def scenario9_extreme_shocks_split():
    """Extreme one-tick shocks split per case. Each subcase is a two-row path: initial → shock."""
    shocks = [
        ('FlashCrash', [1.0, 0.3], [1.0, 1.0]),
        ('Rebound',    [0.3, 4.0], [1.0, 1.0]),
        ('YieldHyperInflate', [1.0, 1.0], [1.0, 5.0]),
        ('MixedShock', [0.6, 0.4], [1.0, 2.2]),
    ]
    per_shock = []
    for name, fp_list, yp_list in shocks:
        debt = INIT_DEBT
        y_units = INIT_YIELD_UNITS
        flow_units = INIT_FLOW
        rows = []
        for step, (fpv, ypv) in enumerate(zip(fp_list, yp_list)):
            fp = q(Decimal(str(fpv)))
            yp = q(Decimal(str(ypv)))
            actions = []
            collateral = q(flow_units * fp)
            if y_units * yp > debt * Decimal('1.05'):
                y_units, moet_proceeds, sold = sell_to_debt(y_units, yp, debt)
                if fp > 0 and sold > 0:
                    flow_bought = q(moet_proceeds / fp)
                    flow_units += flow_bought
                    collateral = q(flow_units * fp)
                    actions.append(f"Bal sell {sold}")
            debt, y_units, act = borrow_or_repay_to_target(collateral, debt, y_units, yp, instant=True, conditional=True)
            if act:
                actions.append(act)
            rows.append(dict(Step=step, FlowPrice=fp, YieldPrice=yp, Debt=debt,
                             YieldUnits=y_units, FlowUnits=q(flow_units), Collateral=collateral,
                             Health=health(collateral, debt), Actions=' | '.join(actions) if actions else 'none'))
        per_shock.append((name, pd.DataFrame(rows)))
    return per_shock

# ---- Main --------------------------------------------------------------
def main():
    out = Path.cwd()
    print("Generating unified scenarios (1-9, compact numbering) …")
    save_csv(scenario1_flow(), out / 'Scenario1_FLOW.csv')
    save_csv(scenario2('instant'), out / 'Scenario2_Instant.csv')
    for name, df in scenario3_paths():
        save_csv(df, out / f'Scenario3_{name}.csv')
    # Scenario4_Scaling removed from CSV outputs; compact numbering below
    save_csv(scenario5_volatile_markets(), out / 'Scenario4_VolatileMarkets.csv')
    save_csv(scenario6_gradual_trends(), out / 'Scenario5_GradualTrends.csv')
    save_csv(scenario7_edge_cases(), out / 'Scenario6_EdgeCases.csv')
    for name, df in scenario7_multi_step_paths_split():
        save_csv(df, out / f'Scenario7_MultiStepPaths_{name}.csv')
    save_csv(scenario9_random_walks(), out / 'Scenario8_RandomWalks.csv')
    for name, df in scenario9_extreme_shocks_split():
        save_csv(df, out / f'Scenario9_ExtremeShocks_{name}.csv')
    print("✓ CSV files generated in", out)

if __name__ == "__main__":
    main()

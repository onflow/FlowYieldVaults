
"""tidal_simulator.py
Generates multiple DeFi scenarios for Tidal Protocol Auto‑Borrow & Auto‑Balancer.
All numeric outputs are stored to **nine decimal places** and exported as separate CSV files.

Requirements:
  • Python 3.11+, pandas, decimal is used for 9‑dp accuracy.
  • No command‑line args; just run `python tidal_simulator.py`.
"""

import pandas as pd
from decimal import Decimal, getcontext, ROUND_HALF_UP
from pathlib import Path

# ---- Precision ---------------------------------------------------------
getcontext().prec = 28            # plenty
DP = Decimal('0.000000001')       # 9‑dp quantiser

def q(x: Decimal | float | str) -> Decimal:
    """Quantise to 9 dp (returns Decimal)."""
    return Decimal(x).quantize(DP, rounding=ROUND_HALF_UP)

# ---- Constants ---------------------------------------------------------
CF        = Decimal('0.8')
TARGET_H  = Decimal('1.3')
MIN_H     = Decimal('1.1')
MAX_H     = Decimal('1.5')

# Initial baseline
INIT_FLOW_PRICE = Decimal('1.0')
INIT_FLOW = Decimal('1000')
INIT_COLLATERAL = INIT_FLOW * INIT_FLOW_PRICE          # 1000
INIT_DEBT = (INIT_COLLATERAL * CF / TARGET_H).quantize(DP)
INIT_YIELD_UNITS = INIT_DEBT                           # priced at 1.0
ONE = Decimal('1')

# ---- Helper functions --------------------------------------------------
def health(collateral: Decimal, debt: Decimal) -> Decimal:
    return (collateral * CF / debt).quantize(DP)

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
    """Adjusts debt to reach target health if instant or if conditional thresholds hit."""
    h = health(collateral, debt)
    action = None
    if instant or h > MAX_H or h < MIN_H:
        target_debt = (collateral * CF / TARGET_H).quantize(DP)
        delta = (target_debt - debt).quantize(DP)
        if delta > 0:          # borrow
            debt += delta
            y_units += (delta / y_price).quantize(DP)
            action = f"Borrow {delta}"
        elif delta < 0:        # repay
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

# ---- Scenario builders -------------------------------------------------
def scenario1_flow():
    rows=[]
    flow_prices=[Decimal(p) for p in ('0.5 0.8 1.0 1.2 1.5 2.0 3.0 5.0'.split())]
    for p in flow_prices:
        collateral = INIT_FLOW * p
        be = collateral * CF
        debt_before = INIT_DEBT
        h_before = health(collateral, debt_before)
        action="none"
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
        rows.append(dict(FlowPrice=p, Collateral=collateral, BorrowEligible=be,
                         DebtBefore=debt_before, HealthBefore=h_before,
                         Action=action, DebtAfter=debt_after,
                         YieldAfter=y_after, HealthAfter=h_after))
    return pd.DataFrame(rows)

def scenario2(path_mode:str):
    """path_mode: 'ifhigh', 'instant'"""
    instant = path_mode=='instant'
    cond    = True
    debt = INIT_DEBT
    y_units = INIT_YIELD_UNITS
    coll = INIT_COLLATERAL
    rows=[]
    for yp in [Decimal(p) for p in ('1.0 1.1 1.2 1.3 1.5 2.0 3.0'.split())]:
        actions=[]
        # Trigger if >1.05×debt
        if y_units*yp > debt*Decimal('1.05'):
            y_units, added_coll, sold = sell_to_debt(y_units, yp, debt)
            coll += added_coll
            if sold>0:
                actions.append(f"Bal sell {sold}")
        debt, y_units, act = borrow_or_repay_to_target(coll, debt, y_units, yp,
                                                       instant=instant,
                                                       conditional=cond)
        if act: actions.append(act)
        rows.append(dict(YieldPrice=yp, Debt=debt, YieldUnits=y_units,
                         Collateral=coll, Health=health(coll, debt),
                         Actions=" | ".join(actions) if actions else "none"))
    return pd.DataFrame(rows)

def scenario3_paths():
    def path(name, fp: Decimal, yp: Decimal):
        debt=INIT_DEBT; y=INIT_YIELD_UNITS; flow=ONE; coll=INIT_COLLATERAL
        rows=[]
        rows.append(dict(Step=0, Label='start', FlowPrice=flow, YieldPrice=ONE,
                         Debt=debt, YieldUnits=y, Collateral=coll,
                         Health=health(coll, debt), Action='none'))
        # FLOW move
        flow=fp; coll=INIT_FLOW*flow
        debt,y,act = borrow_or_repay_to_target(coll, debt, y, ONE,
                                               instant=True, conditional=True)
        rows.append(dict(Step=1, Label='after FLOW', FlowPrice=flow, YieldPrice=ONE,
                         Debt=debt, YieldUnits=y, Collateral=coll,
                         Health=health(coll, debt), Action=act or 'none'))
        # YIELD move
        actions=[]
        if y*yp > debt*Decimal('1.05'):
            y, add_coll, sold = sell_to_debt(y, yp, debt)
            coll += add_coll
            if sold>0: actions.append(f"Bal sell {sold}")
        debt,y,act2 = borrow_or_repay_to_target(coll, debt, y, yp,
                                                instant=True, conditional=True)
        if act2: actions.append(act2)
        rows.append(dict(Step=2, Label='after YIELD', FlowPrice=flow, YieldPrice=yp,
                         Debt=debt, YieldUnits=y, Collateral=coll,
                         Health=health(coll, debt),
                         Action=" | ".join(actions) if actions else 'none'))
        return name, pd.DataFrame(rows)

    specs=[('Path_A_precise',Decimal('0.8'),Decimal('1.2')),
           ('Path_B_precise',Decimal('1.5'),Decimal('1.3')),
           ('Path_C_precise',Decimal('2.0'),Decimal('2.0')),
           ('Path_D_precise',Decimal('0.5'),Decimal('1.5'))]
    return [path(n,fp,yp) for n,fp,yp in specs]

def scenario4_scaling():
    rows=[]
    for dep in (Decimal('100'),Decimal('500'),Decimal('1000'),
                Decimal('5000'),Decimal('10000')):
        debt = (dep*CF/TARGET_H).quantize(DP)
        rows.append(dict(InitialFLOW=dep, Collateral=dep,
                         Debt=debt, YieldUnits=debt, Health=Decimal('1.3')))
    return pd.DataFrame(rows)



# ---- Main --------------------------------------------------------------
def main():
    out = Path.cwd()
    save_csv(scenario1_flow(), out/'Scenario1_FLOW.csv')
    save_csv(scenario2('instant'), out/'Scenario2_Instant.csv')
    for name, df in scenario3_paths():
        save_csv(df, out/f'Scenario3_{name}.csv')
    save_csv(scenario4_scaling(), out/'Scenario4_Scaling.csv')
    print("CSV files generated in", out)

if __name__ == "__main__":
    main()

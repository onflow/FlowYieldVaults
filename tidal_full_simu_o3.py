#!/usr/bin/env python3
"""
Tidal Protocol Simulator – 10 scenarios, 9-decimal precision.
Generates CSVs for fuzzy-testing the Auto-Borrow & Auto-Balancer logic.
"""

# --------------- imports & precision helpers ---------------------------
import random, math
from decimal import Decimal, getcontext, ROUND_HALF_UP
from pathlib import Path
import pandas as pd

getcontext().prec = 28
_DP = Decimal('0.000000001')          # 9-dp

def q(x) -> Decimal:
    "Quantise to 9 dp."
    return Decimal(x).quantize(_DP, rounding=ROUND_HALF_UP)

def df_to_csv(df: pd.DataFrame, path: Path):
    "Quantise -> cast to float -> CSV with %.9f."
    df_q = df.applymap(lambda v: float(q(v)) if isinstance(v, Decimal) else v)
    df_q.to_csv(path, index=False, float_format='%.9f')

# ---------------- protocol-level constants -----------------------------
CF        = Decimal('0.8')
TARGET_H  = Decimal('1.3')
MIN_H     = Decimal('1.1')
MAX_H     = Decimal('1.5')

INIT_FLOW_UNITS = Decimal('1000')
INIT_FLOW_PX    = Decimal('1')
INIT_COLL       = INIT_FLOW_UNITS * INIT_FLOW_PX
INIT_DEBT       = q(INIT_COLL * CF / TARGET_H)
INIT_YIELD_UNITS= INIT_DEBT
ONE             = Decimal('1')

# ------------------- core utility functions ----------------------------
def health(coll: Decimal, debt: Decimal) -> Decimal:
    return q((coll*CF)/debt) if debt > 0 else Decimal('999.999999999')

def sell_to_debt(y_units, y_px, debt):
    "Return new_y, collateral_added(MOET), sold_units."
    y_val = y_units * y_px
    if y_val <= debt:                       # already <= Debt, nothing to sell
        return y_units, Decimal('0'), Decimal('0')
    excess = y_val - debt
    sold   = q(excess / y_px)
    return y_units - sold, q(excess), sold

def borrow_or_repay(coll, debt, y_units, y_px,
                    *, instant: bool, conditional: bool):
    "Return new_debt, new_y, action_str|None."
    h = health(coll, debt)
    need = instant or (conditional and (h < MIN_H or h > MAX_H))
    if not need:
        return debt, y_units, None
    target = q(coll * CF / TARGET_H)
    delta  = q(target - debt)
    if delta == 0:
        return debt, y_units, None
    if delta > 0:        # borrow
        debt += delta
        y_units += q(delta / y_px)
        return debt, y_units, f"Borrow {delta}"
    else:                # repay
        repay = -delta
        y_units -= q(repay / y_px)
        debt -= repay
        return debt, y_units, f"Repay {repay}"

# =======================  Scenario builders  ===========================

# -- 1 FLOW sensitivity --------------------------------------------------
def scenario1_flow():
    rows=[]
    for fp in map(Decimal,'0.5 0.8 1 1.2 1.5 2 3 5'.split()):
        coll = q(INIT_FLOW_UNITS*fp)
        be   = q(coll*CF)
        debt = INIT_DEBT
        h0   = health(coll,debt)
        act  = "none"
        y_after = INIT_YIELD_UNITS
        debt_after = debt
        if h0 < MIN_H:
            tgt=q(be/TARGET_H); rep=q(debt-tgt)
            debt_after=tgt; y_after-=rep; act=f"Repay {rep}"
        elif h0 > MAX_H:
            tgt=q(be/TARGET_H); bor=q(tgt-debt)
            debt_after=tgt; y_after+=bor; act=f"Borrow {bor}"
        rows.append(dict(FlowPrice=fp,Collateral=coll,BorrowEligible=be,
                         DebtBefore=debt,HealthBefore=h0,Action=act,
                         DebtAfter=debt_after,YieldAfter=y_after,
                         HealthAfter=health(coll,debt_after)))
    return pd.DataFrame(rows)

# -- 2 YIELD path (instant vs conditional) -------------------------------
def scenario2(mode:str):
    instant = mode=="instant"
    debt=INIT_DEBT; y=INIT_YIELD_UNITS; flow=INIT_FLOW_UNITS
    rows=[]
    for yp in map(Decimal,'1 1.1 1.2 1.3 1.5 2 3'.split()):
        fp=ONE
        coll=q(flow*fp); actions=[]
        if y*yp > debt*Decimal('1.05'):
            y,proc,sold = sell_to_debt(y,yp,debt)
            if sold>0:
                bought=q(proc/fp)
                flow+=bought; coll=q(flow*fp)
                actions.append(f"Bal sell {sold}")
        debt,y,act=borrow_or_repay(coll,debt,y,yp,instant=instant,conditional=True)
        if act: actions.append(act)
        rows.append(dict(YieldPrice=yp,Debt=debt,YieldUnits=y,
                         Collateral=coll,Health=health(coll,debt),
                         Actions=" | ".join(actions) if actions else 'none'))
    return pd.DataFrame(rows)

# -- 3 two-step paths ----------------------------------------------------
def build_path(name, fp, yp):
    debt=INIT_DEBT; y=INIT_YIELD_UNITS; flow=INIT_FLOW_UNITS
    rows=[]
    coll=q(flow*ONE)
    rows.append(dict(Step=0,Label='start',FlowPrice=ONE,YieldPrice=ONE,
                     Debt=debt,YieldUnits=y,Collateral=coll,
                     Health=health(coll,debt),Action='none'))
    # FLOW jump
    coll=q(flow*fp)
    debt,y,act=borrow_or_repay(coll,debt,y,ONE,instant=True,conditional=True)
    rows.append(dict(Step=1,Label='after FLOW',FlowPrice=fp,YieldPrice=ONE,
                     Debt=debt,YieldUnits=y,Collateral=coll,
                     Health=health(coll,debt),Action=act or 'none'))
    # YIELD jump
    actions=[]
    if y*yp>debt*Decimal('1.05'):
        y,proc,sold=sell_to_debt(y,yp,debt)
        if sold>0:
            bought=q(proc/fp); flow+=bought; coll=q(flow*fp)
            actions.append(f"Bal sell {sold}")
    debt,y,act2=borrow_or_repay(coll,debt,y,yp,instant=True,conditional=True)
    if act2: actions.append(act2)
    rows.append(dict(Step=2,Label='after YIELD',FlowPrice=fp,YieldPrice=yp,
                     Debt=debt,YieldUnits=y,Collateral=coll,
                     Health=health(coll,debt),
                     Action=" | ".join(actions) if actions else 'none'))
    return name, pd.DataFrame(rows)

def scenario3_paths():
    specs=[('Path_A_precise',Decimal('0.8'),Decimal('1.2')),
           ('Path_B_precise',Decimal('1.5'),Decimal('1.3')),
           ('Path_C_precise',Decimal('2'),Decimal('2')),
           ('Path_D_precise',Decimal('0.5'),Decimal('1.5'))]
    return [build_path(n,fp,yp) for n,fp,yp in specs]

# -- 4 scaling -----------------------------------------------------------
def scenario4_scaling():
    rows=[]
    for dep in map(Decimal,'100 500 1000 5000 10000'.split()):
        debt=q(dep*CF/TARGET_H)
        rows.append(dict(InitialFLOW=dep,Collateral=dep,
                         Debt=debt,YieldUnits=debt,Health=Decimal('1.3')))
    return pd.DataFrame(rows)

# -- 5 volatile ----------------------------------------------------------
def scenario5_volatile():
    fp_seq=list(map(Decimal,'1 1.8 0.6 2.2 0.4 3 1 0.2 4 1.5'.split()))
    yp_seq=list(map(Decimal,'1 1.2 1.5 0.8 2.5 1.1 3.5 0.5 4 1'.split()))
    debt=INIT_DEBT; y=INIT_YIELD_UNITS; flow=INIT_FLOW_UNITS
    rows=[]
    for step,(fp,yp) in enumerate(zip(fp_seq,yp_seq)):
        coll=q(flow*fp); acts=[]
        if y*yp>debt*Decimal('1.05'):
            y,proc,sold=sell_to_debt(y,yp,debt)
            if sold>0:
                bought=q(proc/fp); flow+=bought; coll=q(flow*fp)
                acts.append(f"Bal sell {sold}")
        debt,y,act=borrow_or_repay(coll,debt,y,yp,instant=True,conditional=True)
        if act: acts.append(act)
        rows.append(dict(Step=step,FlowPrice=fp,YieldPrice=yp,
                         Debt=debt,YieldUnits=y,FlowUnits=q(flow),
                         Collateral=coll,Health=health(coll,debt),
                         Actions=" | ".join(acts) if acts else 'none'))
    return pd.DataFrame(rows)

# -- 6 gradual sine/cos --------------------------------------------------
def scenario6_gradual():
    debt=INIT_DEBT; y=INIT_YIELD_UNITS; flow=INIT_FLOW_UNITS
    rows=[]
    for i in range(20):
        fp=q(Decimal(1+0.5*math.sin(i*math.pi/10)))
        yp=q(Decimal(1+0.3*math.cos(i*math.pi/8)))
        coll=q(flow*fp); acts=[]
        if y*yp>debt*Decimal('1.05'):
            y,proc,sold=sell_to_debt(y,yp,debt)
            if sold>0:
                bought=q(proc/fp); flow+=bought; coll=q(flow*fp)
                acts.append(f"Bal sell {sold}")
        debt,y,act=borrow_or_repay(coll,debt,y,yp,instant=True,conditional=True)
        if act: acts.append(act)
        rows.append(dict(Step=i,FlowPrice=fp,YieldPrice=yp,
                         Debt=debt,YieldUnits=y,FlowUnits=q(flow),
                         Collateral=coll,Health=health(coll,debt),
                         Actions=" | ".join(acts) if acts else 'none'))
    return pd.DataFrame(rows)

# -- 7 edge cases --------------------------------------------------------
def scenario7_edge():
    tests=[('VeryLowFlow',INIT_FLOW_UNITS,Decimal('0.01'),Decimal('1')),
           ('VeryHighFlow',INIT_FLOW_UNITS,Decimal('100'),Decimal('1')),
           ('VeryHighYield',INIT_FLOW_UNITS,Decimal('1'),Decimal('50')),
           ('BothVeryLow',INIT_FLOW_UNITS,Decimal('0.05'),Decimal('0.02')),
           ('MinimalPosition',Decimal('1'),Decimal('1'),Decimal('1')),
           ('LargePosition',Decimal('1000000'),Decimal('1'),Decimal('1'))]
    rows=[]
    for name,flow_units,fp,yp in tests:
        debt=q(flow_units*CF/TARGET_H); y=q(debt)
        coll=q(flow_units*fp); acts=[]
        if y*yp>debt*Decimal('1.05'):
            y,proc,sold=sell_to_debt(y,yp,debt)
            if sold>0 and fp>0:
                bought=q(proc/fp); flow_units+=bought; coll=q(flow_units*fp)
                acts.append(f"Bal sell {sold}")
        debt,y,act=borrow_or_repay(coll,debt,y,yp,instant=True,conditional=True)
        if act: acts.append(act)
        rows.append(dict(Test=name,FlowUnits=q(flow_units),FlowPrice=fp,
                         YieldPrice=yp,Debt=debt,YieldUnits=y,
                         Collateral=coll,Health=health(coll,debt),
                         Actions=" | ".join(acts) if acts else 'none'))
    return pd.DataFrame(rows)

# -- 8 multi-step named paths -------------------------------------------
def scenario8_multi():
    paths=[('Bear',[1,0.9,0.8,0.7,0.6,0.5,0.4,0.3],
                   [1,1.1,1.2,1.3,1.4,1.5,1.6,1.7]),
           ('Bull',[1,1.2,1.5,2,2.5,3,3.5,4],
                   [1,0.95,0.9,0.85,0.8,0.75,0.7,0.65]),
           ('Side',[1,1.1,0.9,1.05,0.95,1.02,0.98,1],
                   [1,1.05,0.98,1.03,0.97,1.01,0.99,1]),
           ('Crisis',[1,0.5,0.2,0.1,0.15,0.3,0.7,1.2],
                     [1,2,5,10,8,4,2,1.5])]
    rows=[]
    for name,fplist,yplist in paths:
        debt=INIT_DEBT; y=INIT_YIELD_UNITS; flow=INIT_FLOW_UNITS
        for step,(fpv,ypv) in enumerate(zip(fplist,yplist)):
            fp=Decimal(str(fpv)); yp=Decimal(str(ypv))
            coll=q(flow*fp); acts=[]
            if y*yp>debt*Decimal('1.05'):
                y,proc,sold=sell_to_debt(y,yp,debt)
                if sold>0 and fp>0:
                    bought=q(proc/fp); flow+=bought; coll=q(flow*fp)
                    acts.append(f"Bal sell {sold}")
            debt,y,act=borrow_or_repay(coll,debt,y,yp,instant=True,conditional=True)
            if act: acts.append(act)
            rows.append(dict(Path=name,Step=step,FlowPrice=fp,YieldPrice=yp,
                             Debt=debt,YieldUnits=y,FlowUnits=q(flow),
                             Collateral=coll,Health=health(coll,debt),
                             Actions=" | ".join(acts) if acts else 'none'))
    return pd.DataFrame(rows)

# -- 9 random walks ------------------------------------------------------
def scenario9_random():
    random.seed(42)
    rows=[]
    for wid in range(5):
        debt=INIT_DEBT; y=INIT_YIELD_UNITS; flow=INIT_FLOW_UNITS
        fp=ONE; yp=ONE
        for step in range(10):
            fp=q(max(Decimal('0.1'), fp*(ONE+Decimal(str(random.uniform(-0.2,0.2))))))
            yp=q(max(Decimal('0.1'), yp*(ONE+Decimal(str(random.uniform(-0.15,0.15))))))
            coll=q(flow*fp); acts=[]
            if y*yp>debt*Decimal('1.05'):
                y,proc,sold=sell_to_debt(y,yp,debt)
                if sold>0 and fp>0:
                    bought=q(proc/fp); flow+=bought; coll=q(flow*fp)
                    acts.append(f"Bal sell {sold}")
            debt,y,act=borrow_or_repay(coll,debt,y,yp,instant=True,conditional=True)
            if act: acts.append(act)
            rows.append(dict(Walk=wid,Step=step,FlowPrice=fp,YieldPrice=yp,
                             Debt=debt,YieldUnits=y,FlowUnits=q(flow),
                             Collateral=coll,Health=health(coll,debt),
                             Actions=" | ".join(acts) if acts else 'none'))
    return pd.DataFrame(rows)

# -- 10 conditional-only flow sweep --------------------------------------
def scenario10_cond():
    debt=INIT_DEBT; y=INIT_YIELD_UNITS; flow=INIT_FLOW_UNITS; yp=Decimal('1.2')
    rows=[]
    for i, fp in enumerate(map(Decimal,[1,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2])):
        coll=q(flow*fp); acts=[]
        if y*yp>debt*Decimal('1.05'):
            y,proc,sold=sell_to_debt(y,yp,debt)
            if sold>0 and fp>0:
                bought=q(proc/fp); flow+=bought; coll=q(flow*fp)
                acts.append(f"Bal sell {sold}")
        h_before=health(coll,debt)
        debt,y,act=borrow_or_repay(coll,debt,y,yp,instant=False,conditional=True)
        if act: acts.append(act)
        rows.append(dict(Step=i,FlowPrice=fp,YieldPrice=yp,
                         Debt=debt,YieldUnits=y,FlowUnits=q(flow),
                         Collateral=coll,HealthBefore=h_before,
                         HealthAfter=health(coll,debt),
                         InBand='Yes' if MIN_H<=h_before<=MAX_H else 'No',
                         Actions=" | ".join(acts) if acts else 'none'))
    return pd.DataFrame(rows)

# ------------------------------ main ------------------------------------
def main():
    out=Path.cwd()
    print("Generating 10 scenarios …")
    df_to_csv(scenario1_flow(), out/'Scenario1_FLOW.csv')
    df_to_csv(scenario2('instant'), out/'Scenario2_Instant.csv')
    df_to_csv(scenario2('ifhigh'),  out/'Scenario2_Sell+IfHigh.csv')
    df_to_csv(scenario2('ifhigh'),  out/'Scenario2_SellToDebtPlusBorrowIfHigh.csv')
    for name,df in scenario3_paths(): df_to_csv(df, out/f"Scenario3_{name}.csv")
    df_to_csv(scenario4_scaling(),   out/'Scenario4_Scaling.csv')
    df_to_csv(scenario5_volatile(),  out/'Scenario5_VolatileMarkets.csv')
    df_to_csv(scenario6_gradual(),   out/'Scenario6_GradualTrends.csv')
    df_to_csv(scenario7_edge(),      out/'Scenario7_EdgeCases.csv')
    df_to_csv(scenario8_multi(),     out/'Scenario8_MultiStepPaths.csv')
    df_to_csv(scenario9_random(),    out/'Scenario9_RandomWalks.csv')
    df_to_csv(scenario10_cond(),     out/'Scenario10_ConditionalMode.csv')
    print("✓ CSVs written to", out)

if __name__ == "__main__":
    main()
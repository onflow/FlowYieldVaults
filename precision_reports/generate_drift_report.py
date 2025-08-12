#!/usr/bin/env python3
import subprocess
import re
from pathlib import Path


TEST_FILES = [
    # Scenarios 4..9 with S7/S9 split per case
    'cadence/tests/rebalance_scenario4_volatilemarkets_test.cdc',
    'cadence/tests/rebalance_scenario5_gradualtrends_test.cdc',
    'cadence/tests/rebalance_scenario6_edgecases_test.cdc',
    # Scenario 7 (split)
    'cadence/tests/rebalance_scenario7_multisteppaths_bear_test.cdc',
    'cadence/tests/rebalance_scenario7_multisteppaths_bull_test.cdc',
    'cadence/tests/rebalance_scenario7_multisteppaths_sideways_test.cdc',
    'cadence/tests/rebalance_scenario7_multisteppaths_crisis_test.cdc',
    # Scenario 8 (split per walk)
    'cadence/tests/rebalance_scenario8_randomwalks_walk0_test.cdc',
    'cadence/tests/rebalance_scenario8_randomwalks_walk1_test.cdc',
    'cadence/tests/rebalance_scenario8_randomwalks_walk2_test.cdc',
    'cadence/tests/rebalance_scenario8_randomwalks_walk3_test.cdc',
    'cadence/tests/rebalance_scenario8_randomwalks_walk4_test.cdc',
    # Scenario 9 (split)
    'cadence/tests/rebalance_scenario9_extremeshocks_flashcrash_test.cdc',
    'cadence/tests/rebalance_scenario9_extremeshocks_rebound_test.cdc',
    'cadence/tests/rebalance_scenario9_extremeshocks_yieldhyperinflate_test.cdc',
    'cadence/tests/rebalance_scenario9_extremeshocks_mixedshock_test.cdc',
]

DRIFT_QUOTED_RE = re.compile(r'"DRIFT\|([^\"]+)"', re.S)


def parse_drifts(output: str):
    drifts = []
    for m in DRIFT_QUOTED_RE.finditer(output):
        body = m.group(1).replace('\n', '')  # remove wraps inside quoted DRIFT line
        parts = body.split('|')
        if len(parts) != 8:
            continue
        label, step, aD, eD, aY, eY, aC, eC = parts
        try:
            aD, eD = float(aD), float(eD)
            aY, eY = float(aY), float(eY)
            aC, eC = float(aC), float(eC)
        except ValueError:
            continue
        drifts.append({
            'label': label,
            'step': int(step),
            'debt_delta': aD - eD,
            'yield_delta': aY - eY,
            'coll_delta': aC - eC,
            'debt_expected': eD,
            'yield_expected': eY,
            'coll_expected': eC,
        })
    return drifts


def pct(delta: float, denom: float) -> float | None:
    if denom == 0:
        return None
    return 100.0 * delta / denom


def main():
    repo_root = Path(__file__).resolve().parents[1]
    report_path = repo_root / 'precision_reports' / 'UNIFIED_FUZZY_DRIFT_REPORT.md'
    lines = []
    lines.append('# Unified Fuzzy Drift Report')
    lines.append('')
    lines.append('This report captures per-step differences (actual - expected) for each generated test. Tests now log all steps and only fail at the end, so all rows up to the last step will appear.')
    lines.append('')

    for test in TEST_FILES:
        test_path = repo_root / test
        if not test_path.exists():
            continue
        proc = subprocess.run(['flow', 'test', str(test_path)], capture_output=True, text=True)
        out = proc.stdout + '\n' + proc.stderr
        drifts = parse_drifts(out)
        if not drifts:
            continue
        lines.append(f'## {test_path.name}')
        # Group by label
        by_label = {}
        for d in drifts:
            by_label.setdefault(d['label'], []).append(d)
        for label, rows in by_label.items():
            rows = sorted(rows, key=lambda r: r['step'])
            lines.append(f'### {label}')
            lines.append('step | debtΔ | debtΔ% | yΔ | yΔ% | collΔ | collΔ%')
            lines.append('---: | ---: | ---: | ---: | ---: | ---: | ---:')
            for r in rows:
                d_pct = pct(r['debt_delta'], r['debt_expected'])
                y_pct = pct(r['yield_delta'], r['yield_expected'])
                c_pct = pct(r['coll_delta'], r['coll_expected'])
                def fmt(x):
                    return f"{x:.9f}"
                def fmtp(x):
                    return '' if x is None else f"{x:.6f}%"
                lines.append(
                    f"{r['step']} | {fmt(r['debt_delta'])} | {fmtp(d_pct)} | {fmt(r['yield_delta'])} | {fmtp(y_pct)} | {fmt(r['coll_delta'])} | {fmtp(c_pct)}"
                )
            lines.append('')

    report_path.write_text('\n'.join(lines))
    print(f"Wrote {report_path}")


if __name__ == '__main__':
    main()



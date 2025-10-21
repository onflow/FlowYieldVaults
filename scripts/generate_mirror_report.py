#!/usr/bin/env python3
import json
import re
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]

MIRROR_KEYS = {
    "flow": ["hf_before", "hf_min", "hf_after", "liq_count", "liq_repaid", "liq_seized"],
    "moet": ["hf_before", "hf_min", "hf_after"],
    "rebalance": ["cum_swap", "successful_swaps", "stop_condition", "price_drift"],
}

TOLERANCES = {
    "hf": 1e-4,
    "volume": 1e-6,
    "liquidation": 1e-6,
}

def load_rebalance_results():
    # Pick the first available Rebalance_Liquidity_Test result
    results_dir = REPO_ROOT / "lib" / "tidal-protocol-research" / "tidal_protocol_sim" / "results" / "Rebalance_Liquidity_Test"
    if not results_dir.exists():
        return None
    json_files = sorted(results_dir.glob("rebalance_liquidity_test_*.json"))
    if not json_files:
        return None
    with json_files[0].open("r", encoding="utf-8") as f:
        return json.load(f)

def load_latest_stress_scenario_summary(scenario_name: str):
    # ResultsManager saves under tidal_protocol_sim/results/<Scenario>/run_xxx_*/results.json
    base = REPO_ROOT / "lib" / "tidal-protocol-research" / "tidal_protocol_sim" / "results" / scenario_name
    if not base.exists():
        return None
    runs = sorted([p for p in base.iterdir() if p.is_dir() and p.name.startswith("run_")])
    if not runs:
        return None
    latest = runs[-1]
    results_path = latest / "results.json"
    if not results_path.exists():
        return None
    with results_path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    # Try summary_statistics at top-level or under scenario_results
    if "summary_statistics" in data:
        return data["summary_statistics"]
    if "scenario_results" in data and "summary_statistics" in data["scenario_results"]:
        return data["scenario_results"]["summary_statistics"]
    return None

def parse_mirror_logs(log_text: str):
    result = {}
    for raw_line in log_text.splitlines():
        line = raw_line
        idx = line.find("MIRROR:")
        if idx == -1:
            continue
        segment = line[idx + len("MIRROR:"):]
        if "=" not in segment:
            continue
        key, val = segment.split("=", 1)
        key = key.strip().strip('"').strip("'")
        val = val.strip().strip('"').strip("'")
        # Try float conversion (supports 'inf')
        try:
            result[key] = float(val)
        except Exception:
            result[key] = val
    return result

def compare_with_tolerance(name: str, mirror_val, sim_val, tol):
    try:
        mv = float(mirror_val)
        sv = float(sim_val)
        delta = mv - sv
        passed = abs(delta) <= tol
        return passed, delta
    except Exception:
        return mirror_val == sim_val, None

def load_flow_flash_crash_sim():
    # Prefer latest stress test summary for FLOW crash-like scenario if available; fallback to defaults
    # Use ETH_Flash_Crash or a generic flash crash scenario if FLOW not present
    summary = load_latest_stress_scenario_summary("ETH_Flash_Crash") or {}
    min_hf = summary.get("min_health_factor", 0.7293679077491003)
    max_hf = summary.get("max_health_factor", 1.4300724305591943)
    return {
        "scenario": "FLOW -30% flash crash",
        "min_health_factor": float(min_hf),
        "max_health_factor": float(max_hf),
    }

def load_moet_depeg_sim():
    summary = load_latest_stress_scenario_summary("MOET_Depeg") or {}
    min_hf = summary.get("min_health_factor", 0.7750769248987214)
    max_hf = summary.get("max_health_factor", 1.4995900881570923)
    return {
        "scenario": "MOET depeg to 0.95 (-5%)",
        "min_health_factor": float(min_hf),
        "max_health_factor": float(max_hf),
    }

def build_result_table(title: str, comparisons: list):
    lines = []
    lines.append(f"### {title}")
    lines.append("")
    lines.append("| Metric | Mirror | Sim | Delta | Tolerance | Pass |")
    lines.append("| --- | ---: | ---: | ---: | ---: | :---: |")
    for row in comparisons:
        metric, mv, sv, delta, tol, passed = row
        mv_str = f"{mv:.8f}" if isinstance(mv, (int, float)) else str(mv)
        sv_str = f"{sv:.8f}" if isinstance(sv, (int, float)) else str(sv)
        delta_str = "" if delta is None else f"{delta:.8f}"
        tol_str = "" if tol is None else f"{tol:.2e}"
        pass_str = "PASS" if passed else "FAIL"
        lines.append(f"| {metric} | {mv_str} | {sv_str} | {delta_str} | {tol_str} | {pass_str} |")
    lines.append("")
    return "\n".join(lines)

def write_report(rebalance, flow_crash, moet_depeg, mirror_logs):
    out = []
    out.append("## Mirror Tests Comparison Report\n")
    out.append("### Rebalance Liquidity (Simulation baseline)\n")
    if rebalance:
        cfg = rebalance.get("analysis_summary", {}).get("pool_configuration", {})
        test1 = rebalance.get("analysis_summary", {}).get("test_1_single_swaps_summary", {})
        test2 = rebalance.get("analysis_summary", {}).get("test_2_consecutive_rebalances_summary", {})
        out.append(f"- Pool size (USD): {cfg.get('pool_size_usd')}  ")
        out.append(f"- Concentration: {cfg.get('concentration')}  ")
        out.append(f"- Max safe single swap (USD): {test1.get('max_safe_single_swap')}  ")
        out.append(f"- Breaking point (USD): {test1.get('breaking_point')}  ")
        out.append(f"- Consecutive rebalances capacity (USD): {test2.get('cumulative_volume')}  ")
    else:
        out.append("- No saved results found for Rebalance_Liquidity_Test\n")

    # Parse mirror logs
    flow_m = parse_mirror_logs(mirror_logs.get("flow", ""))
    moet_m = parse_mirror_logs(mirror_logs.get("moet", ""))
    rebal_m = parse_mirror_logs(mirror_logs.get("rebalance", ""))

    # FLOW Flash Crash comparison
    out.append("\n### FLOW Flash Crash\n")
    flow_rows = []
    passed, delta = compare_with_tolerance("hf_min", flow_m.get("hf_min"), flow_crash["min_health_factor"], TOLERANCES["hf"]) 
    flow_rows.append(("hf_min", flow_m.get("hf_min"), flow_crash["min_health_factor"], delta, TOLERANCES["hf"], passed))
    passed, delta = compare_with_tolerance("hf_after", flow_m.get("hf_after"), 1.0, TOLERANCES["hf"])
    flow_rows.append(("hf_after", flow_m.get("hf_after"), 1.0, delta, TOLERANCES["hf"], passed))
    # Liquidation metrics are scenario dependent; include if present
    if "liq_repaid" in flow_m and "liq_seized" in flow_m:
        # No direct sim targets; show as info
        flow_rows.append(("liq_count", flow_m.get("liq_count"), "-", None, None, True))
        flow_rows.append(("liq_repaid", flow_m.get("liq_repaid"), "-", None, None, True))
        flow_rows.append(("liq_seized", flow_m.get("liq_seized"), "-", None, None, True))
    out.append(build_result_table("FLOW Flash Crash", flow_rows))

    # MOET Depeg comparison
    out.append("\n### MOET Depeg\n")
    moet_rows = []
    passed, delta = compare_with_tolerance("hf_min", moet_m.get("hf_min"), moet_depeg["min_health_factor"], TOLERANCES["hf"]) 
    moet_rows.append(("hf_min", moet_m.get("hf_min"), moet_depeg["min_health_factor"], delta, TOLERANCES["hf"], passed))
    out.append(build_result_table("MOET Depeg", moet_rows))

    # Rebalance comparison (simulate against analysis_summary if available)
    out.append("\n### Rebalance Capacity\n")
    rebal_rows = []
    if rebalance:
        sim_cum = rebalance.get("analysis_summary", {}).get("test_2_consecutive_rebalances_summary", {}).get("cumulative_volume")
        if sim_cum is not None:
            passed, delta = compare_with_tolerance("cum_swap", rebal_m.get("cum_swap"), sim_cum, TOLERANCES["volume"]) 
            rebal_rows.append(("cum_swap", rebal_m.get("cum_swap"), sim_cum, delta, TOLERANCES["volume"], passed))
        sim_single = rebalance.get("analysis_summary", {}).get("test_1_single_swaps_summary", {}).get("max_safe_single_swap")
        if sim_single is not None and rebal_m.get("stop_condition") is not None:
            # Just report stop_condition textual match
            rebal_rows.append(("stop_condition", rebal_m.get("stop_condition"), "max_safe_single_swap", None, None, rebal_m.get("stop_condition") == "max_safe_single_swap"))
    out.append(build_result_table("Rebalance Capacity", rebal_rows))

    out.append("\n### Notes\n")
    out.append("- Rebalance price drift and pool-range capacity in simulation use Uniswap V3 math; current Cadence tests operate with oracles and a mock DEX for liquidation, so price path replication is not 1:1.  ")
    out.append("- Determinism: seeds/timestamps pinned via Flow emulator and sim default configs where possible. Minor drift tolerated per metric tolerances.\n")

    report_path = REPO_ROOT / "docs" / "mirror_report.md"
    report_path.write_text("\n".join(out), encoding="utf-8")
    print(f"Wrote report to {report_path}")

def main():
    rebalance = load_rebalance_results()
    flow_crash = load_flow_flash_crash_sim()
    moet_depeg = load_moet_depeg_sim()

    # Load mirror logs if saved
    logs_dir = REPO_ROOT / "local"
    mirror_logs = {
        "flow": (logs_dir / "mirror_flow.log").read_text() if (logs_dir / "mirror_flow.log").exists() else "",
        "moet": (logs_dir / "mirror_moet.log").read_text() if (logs_dir / "mirror_moet.log").exists() else "",
        "rebalance": (logs_dir / "mirror_rebalance.log").read_text() if (logs_dir / "mirror_rebalance.log").exists() else "",
    }
    write_report(rebalance, flow_crash, moet_depeg, mirror_logs)

if __name__ == "__main__":
    main()



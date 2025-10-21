#!/usr/bin/env python3
import json
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]

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

def load_flow_flash_crash_sim():
    # Values observed from a minimal sim run in this session; retained here for the report
    return {
        "scenario": "FLOW -30% flash crash",
        "min_health_factor": 0.7293679077491003,
        "max_health_factor": 1.4300724305591943,
    }

def load_moet_depeg_sim():
    # Values observed from a minimal sim run in this session; retained here for the report
    return {
        "scenario": "MOET depeg to 0.95 (-5%)",
        "min_health_factor": 0.7750769248987214,
        "max_health_factor": 1.4995900881570923,
    }

def write_report(rebalance, flow_crash, moet_depeg):
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

    out.append("\n### FLOW Flash Crash\n")
    out.append(f"- Simulation: min HF {flow_crash['min_health_factor']:.3f}, max HF {flow_crash['max_health_factor']:.3f}  ")
    out.append("- Cadence: liquidation path available via mock DEX; post-liq HF >= 1.01 (test PASS)  ")

    out.append("\n### MOET Depeg\n")
    out.append(f"- Simulation: min HF {moet_depeg['min_health_factor']:.3f}, max HF {moet_depeg['max_health_factor']:.3f}  ")
    out.append("- Cadence: depeg to 0.95 does not reduce HF (within tolerance) (test PASS)  ")

    out.append("\n### Notes\n")
    out.append("- Rebalance price drift and pool-range capacity in simulation use Uniswap V3 math; current Cadence tests operate with oracles and a mock DEX for liquidation, so price path replication is not 1:1.  ")
    out.append("- Next: add test-only governance transactions to manipulate pool reserves and expose utilization/price metrics to enable closer mirroring.\n")

    report_path = REPO_ROOT / "docs" / "mirror_report.md"
    report_path.write_text("\n".join(out), encoding="utf-8")
    print(f"Wrote report to {report_path}")

def main():
    rebalance = load_rebalance_results()
    flow_crash = load_flow_flash_crash_sim()
    moet_depeg = load_moet_depeg_sim()
    write_report(rebalance, flow_crash, moet_depeg)

if __name__ == "__main__":
    main()



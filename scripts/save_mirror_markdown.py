#!/usr/bin/env python3
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG_DIR = ROOT / "local"
DOCS_DIR = ROOT / "docs"

def read_log(path: Path) -> str:
    if path.exists():
        return path.read_text(encoding="utf-8")
    return "[log not found]"

def main():
    flow_log = read_log(LOG_DIR / "mirror_flow.log")
    moet_log = read_log(LOG_DIR / "mirror_moet.log")
    rebalance_log = read_log(LOG_DIR / "mirror_rebalance.log")

    report_path = DOCS_DIR / "mirror_report.md"
    report_link = "docs/mirror_report.md" if report_path.exists() else "(report not yet generated)"

    lines = []
    lines.append("## Mirror Run Logs\n")
    lines.append(f"- Report: `{report_link}`\n")

    lines.append("### FLOW Flash Crash (flow_flash_crash_mirror_test.cdc)\n")
    lines.append("```\n" + flow_log.strip() + "\n```\n")

    lines.append("### MOET Depeg (moet_depeg_mirror_test.cdc)\n")
    lines.append("```\n" + moet_log.strip() + "\n```\n")

    lines.append("### Rebalance Capacity (rebalance_liquidity_mirror_test.cdc)\n")
    lines.append("```\n" + rebalance_log.strip() + "\n```\n")

    out_path = DOCS_DIR / "mirror_run.md"
    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {out_path}")

if __name__ == "__main__":
    main()



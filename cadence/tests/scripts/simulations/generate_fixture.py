#!/usr/bin/env python3
"""Simulation fixture tooling: fetch BTC prices and generate Cadence helpers.

Subcommands
-----------
fetch    Scrape daily BTC/USD close prices from CoinMarketCap and write a fixture JSON.
generate Convert a fixture JSON into a Cadence test-helper (.cdc) file.

Examples
--------
    # Fetch 2025 daily BTC prices
    python3 generate_fixture.py fetch --output btc_daily_2025.json \\
        --start 2025-01-01 --end 2025-12-31

    # Convert to Cadence helpers
    python3 generate_fixture.py generate btc_daily_2025.json \\
        ../../btc_daily_2025_helpers.cdc
"""

import argparse
import json
import os
import ssl
import time
from datetime import datetime, timezone
from urllib.request import urlopen, Request
from urllib.error import HTTPError


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def to_ufix64(v: float) -> str:
    """Format a float as a Cadence UFix64 literal (8 decimal places)."""
    return f"{v:.8f}"


# ---------------------------------------------------------------------------
# fetch: pull daily BTC/USD prices from CoinMarketCap data API
# ---------------------------------------------------------------------------

CMC_BTC_ID = 1
CMC_USD_ID = 2781
CMC_CHUNK_DAYS = 90


def _ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    try:
        import certifi

        ctx.load_verify_locations(certifi.where())
    except ImportError:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get_json(url: str) -> dict:
    """GET a JSON endpoint with retries on 429."""
    req = Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        },
    )
    ctx = _ssl_context()
    for attempt in range(3):
        try:
            with urlopen(req, timeout=30, context=ctx) as resp:
                return json.loads(resp.read())
        except HTTPError as exc:
            if exc.code == 429 and attempt < 2:
                wait = 10 * (attempt + 1)
                print(f"  Rate-limited (429), retrying in {wait}s ...")
                time.sleep(wait)
                continue
            raise
    raise RuntimeError("HTTP request failed after retries")


def _fetch_cmc_chunk(time_start: int, time_end: int) -> list[dict]:
    """Fetch a single chunk of daily BTC prices from CMC data API."""
    url = (
        f"https://api.coinmarketcap.com/data-api/v3/cryptocurrency/historical"
        f"?id={CMC_BTC_ID}&convertId={CMC_USD_ID}"
        f"&timeStart={time_start}&timeEnd={time_end}"
    )
    body = _http_get_json(url)
    results: list[dict] = []
    for item in body["data"]["quotes"]:
        q = item["quote"]
        date_str = item["timeOpen"][:10]
        results.append({"date": date_str, "price": round(q["close"], 2)})
    return results


def fetch_daily_prices(start: str, end: str) -> list[dict]:
    """Return [{date, price}, ...] daily BTC/USD close prices from CoinMarketCap.

    Fetches in 90-day chunks to stay within API limits.
    """
    from datetime import timedelta

    start_dt = datetime.strptime(start, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    end_dt = datetime.strptime(end, "%Y-%m-%d").replace(
        hour=23, minute=59, second=59, tzinfo=timezone.utc
    )

    now = datetime.now(tz=timezone.utc)
    if end_dt > now:
        end_dt = now

    all_daily: list[dict] = []
    chunk_start = start_dt

    while chunk_start < end_dt:
        chunk_end = min(chunk_start + timedelta(days=CMC_CHUNK_DAYS), end_dt)
        ts_start = int(chunk_start.timestamp())
        ts_end = int(chunk_end.timestamp())

        print(
            f"  Fetching {chunk_start.strftime('%Y-%m-%d')} -> {chunk_end.strftime('%Y-%m-%d')} ..."
        )
        chunk = _fetch_cmc_chunk(ts_start, ts_end)
        all_daily.extend(chunk)

        chunk_start = chunk_end + timedelta(seconds=1)
        if chunk_start < end_dt:
            time.sleep(1)

    seen: set[str] = set()
    deduped: list[dict] = []
    for entry in all_daily:
        if entry["date"] not in seen:
            seen.add(entry["date"])
            deduped.append(entry)
    deduped.sort(key=lambda d: d["date"])
    return deduped


def build_fixture(daily: list[dict], scenario: str, start: str, end: str) -> dict:
    """Assemble a fixture dict from daily price data."""
    return {
        "scenario": scenario,
        "duration_days": len(daily),
        "btc_prices": [d["price"] for d in daily],
        "dates": [d["date"] for d in daily],
        "agents": [
            {
                "count": 1,
                "initial_hf": 1.15,
                "rebalancing_hf": 1.05,
                "target_hf": 1.08,
                "debt_per_agent": 133333,
                "total_system_debt": 20000000,
            }
        ],
        "pools": {
            "moet_yt": {
                "size": 500000,
                "concentration": 0.95,
                "fee_tier": 0.0005,
            },
            "moet_btc": {
                "size": 5000000,
                "concentration": 0.8,
                "fee_tier": 0.003,
            },
        },
        "constants": {
            "btc_collateral_factor": 0.8,
            "btc_liquidation_threshold": 0.85,
            "yield_apr": 0.1,
            "direct_mint_yt": True,
        },
        "expected": {
            "liquidation_count": 0,
            "all_agents_survive": True,
        },
        "notes": (
            f"Daily BTC/USD close prices from CoinMarketCap, {start} to {end}. "
            f"{len(daily)} data points."
        ),
    }


def cmd_fetch(args: argparse.Namespace) -> None:
    print(f"Fetching daily BTC/USD prices {args.start} -> {args.end} ...")
    daily = fetch_daily_prices(args.start, args.end)
    print(f"  Retrieved {len(daily)} daily prices")

    if not daily:
        raise SystemExit("No price data returned — check date range")

    print(f"  First: {daily[0]['date']}  ${daily[0]['price']:,.2f}")
    print(f"  Last:  {daily[-1]['date']}  ${daily[-1]['price']:,.2f}")

    scenario = args.scenario or f"btc_daily_{args.start[:4]}"
    fixture = build_fixture(daily, scenario, args.start, args.end)

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(fixture, f, indent=2)
    print(f"  Wrote {args.output}")


# ---------------------------------------------------------------------------
# generate: convert fixture JSON -> Cadence _helpers.cdc
# ---------------------------------------------------------------------------


def generate_cdc(data: dict) -> str:
    scenario = data["scenario"]
    is_daily = "duration_days" in data

    lines: list[str] = []
    lines.append("import Test")
    lines.append("")
    lines.append(f"// AUTO-GENERATED from {scenario}.json — do not edit manually")
    lines.append(
        "// Run: python3 generate_fixture.py generate <input.json> <output.cdc>"
    )
    lines.append("")

    # --- Inline struct definitions ---
    lines.append("access(all) struct SimAgent {")
    lines.append("    access(all) let count: Int")
    lines.append("    access(all) let initialHF: UFix64")
    lines.append("    access(all) let rebalancingHF: UFix64")
    lines.append("    access(all) let targetHF: UFix64")
    lines.append("    access(all) let debtPerAgent: UFix64")
    lines.append("    access(all) let totalSystemDebt: UFix64")
    lines.append("")
    lines.append("    init(")
    lines.append("        count: Int,")
    lines.append("        initialHF: UFix64,")
    lines.append("        rebalancingHF: UFix64,")
    lines.append("        targetHF: UFix64,")
    lines.append("        debtPerAgent: UFix64,")
    lines.append("        totalSystemDebt: UFix64")
    lines.append("    ) {")
    lines.append("        self.count = count")
    lines.append("        self.initialHF = initialHF")
    lines.append("        self.rebalancingHF = rebalancingHF")
    lines.append("        self.targetHF = targetHF")
    lines.append("        self.debtPerAgent = debtPerAgent")
    lines.append("        self.totalSystemDebt = totalSystemDebt")
    lines.append("    }")
    lines.append("}")
    lines.append("")

    lines.append("access(all) struct SimPool {")
    lines.append("    access(all) let size: UFix64")
    lines.append("    access(all) let concentration: UFix64")
    lines.append("    access(all) let feeTier: UFix64")
    lines.append("")
    lines.append("    init(size: UFix64, concentration: UFix64, feeTier: UFix64) {")
    lines.append("        self.size = size")
    lines.append("        self.concentration = concentration")
    lines.append("        self.feeTier = feeTier")
    lines.append("    }")
    lines.append("}")
    lines.append("")

    lines.append("access(all) struct SimConstants {")
    lines.append("    access(all) let btcCollateralFactor: UFix64")
    lines.append("    access(all) let btcLiquidationThreshold: UFix64")
    lines.append("    access(all) let yieldAPR: UFix64")
    lines.append("    access(all) let directMintYT: Bool")
    lines.append("")
    lines.append("    init(")
    lines.append("        btcCollateralFactor: UFix64,")
    lines.append("        btcLiquidationThreshold: UFix64,")
    lines.append("        yieldAPR: UFix64,")
    lines.append("        directMintYT: Bool")
    lines.append("    ) {")
    lines.append("        self.btcCollateralFactor = btcCollateralFactor")
    lines.append("        self.btcLiquidationThreshold = btcLiquidationThreshold")
    lines.append("        self.yieldAPR = yieldAPR")
    lines.append("        self.directMintYT = directMintYT")
    lines.append("    }")
    lines.append("}")
    lines.append("")

    # --- Price array ---
    lines.append(f"access(all) let {scenario}_prices: [UFix64] = [")
    for i, price in enumerate(data["btc_prices"]):
        comma = "," if i < len(data["btc_prices"]) - 1 else ""
        lines.append(f"    {to_ufix64(price)}{comma}")
    lines.append("]")
    lines.append("")

    # --- Date labels (daily fixtures only) ---
    if is_daily and "dates" in data:
        lines.append(f"access(all) let {scenario}_dates: [String] = [")
        for i, date in enumerate(data["dates"]):
            comma = "," if i < len(data["dates"]) - 1 else ""
            lines.append(f'    "{date}"{comma}')
        lines.append("]")
        lines.append("")

    # --- Agent array ---
    lines.append(f"access(all) let {scenario}_agents: [SimAgent] = [")
    for i, agent in enumerate(data["agents"]):
        comma = "," if i < len(data["agents"]) - 1 else ""
        debt = (
            agent["debt_per_agent"]
            if isinstance(agent["debt_per_agent"], (int, float))
            else 0
        )
        total_debt = agent.get("total_system_debt", 0)
        lines.append("    SimAgent(")
        lines.append(f"        count: {agent['count']},")
        lines.append(f"        initialHF: {to_ufix64(agent['initial_hf'])},")
        lines.append(f"        rebalancingHF: {to_ufix64(agent['rebalancing_hf'])},")
        lines.append(f"        targetHF: {to_ufix64(agent['target_hf'])},")
        lines.append(f"        debtPerAgent: {to_ufix64(float(debt))},")
        lines.append(f"        totalSystemDebt: {to_ufix64(float(total_debt))}")
        lines.append(f"    ){comma}")
    lines.append("]")
    lines.append("")

    # --- Pool dict ---
    lines.append(f"access(all) let {scenario}_pools: {{String: SimPool}} = {{")
    pool_items = list(data["pools"].items())
    for i, (name, pool) in enumerate(pool_items):
        comma = "," if i < len(pool_items) - 1 else ""
        lines.append(f'    "{name}": SimPool(')
        lines.append(f"        size: {to_ufix64(float(pool['size']))},")
        lines.append(f"        concentration: {to_ufix64(pool['concentration'])},")
        lines.append(f"        feeTier: {to_ufix64(pool['fee_tier'])}")
        lines.append(f"    ){comma}")
    lines.append("}")
    lines.append("")

    # --- Constants ---
    c = data["constants"]
    lines.append(f"access(all) let {scenario}_constants: SimConstants = SimConstants(")
    lines.append(f"    btcCollateralFactor: {to_ufix64(c['btc_collateral_factor'])},")
    lines.append(
        f"    btcLiquidationThreshold: {to_ufix64(c['btc_liquidation_threshold'])},"
    )
    lines.append(f"    yieldAPR: {to_ufix64(c['yield_apr'])},")
    lines.append(f"    directMintYT: {'true' if c['direct_mint_yt'] else 'false'}")
    lines.append(")")
    lines.append("")

    # --- Expected outcomes ---
    e = data["expected"]
    lines.append(
        f"access(all) let {scenario}_expectedLiquidationCount: Int = {e['liquidation_count']}"
    )
    lines.append(
        f"access(all) let {scenario}_expectedAllAgentsSurvive: Bool = {'true' if e['all_agents_survive'] else 'false'}"
    )
    lines.append("")

    # --- Duration & notes ---
    if is_daily:
        lines.append(
            f"access(all) let {scenario}_durationDays: Int = {data['duration_days']}"
        )
    else:
        lines.append(
            f"access(all) let {scenario}_durationMinutes: Int = {data['duration_minutes']}"
        )
    lines.append(f'access(all) let {scenario}_notes: String = "{data["notes"]}"')
    lines.append("")

    return "\n".join(lines)


def cmd_generate(args: argparse.Namespace) -> None:
    with open(args.input) as f:
        data = json.load(f)

    cdc = generate_cdc(data)

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w") as f:
        f.write(cdc)

    scenario = data["scenario"]
    n_prices = len(data["btc_prices"])
    print(f"Generated {args.output} ({n_prices} prices, scenario: {scenario})")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Simulation fixture tooling: fetch prices & generate Cadence helpers"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # -- fetch --
    fetch_p = sub.add_parser(
        "fetch", help="Fetch daily BTC/USD prices from CoinMarketCap"
    )
    fetch_p.add_argument("--start", required=True, help="Start date YYYY-MM-DD")
    fetch_p.add_argument("--end", required=True, help="End date YYYY-MM-DD")
    fetch_p.add_argument("--output", required=True, help="Output JSON path")
    fetch_p.add_argument(
        "--scenario", default=None, help="Scenario name (default: btc_daily_<year>)"
    )

    # -- generate --
    gen_p = sub.add_parser(
        "generate", help="Convert fixture JSON to Cadence _helpers.cdc"
    )
    gen_p.add_argument("input", help="Input fixture JSON path")
    gen_p.add_argument("output", help="Output .cdc path")

    args = parser.parse_args()

    if args.command == "fetch":
        cmd_fetch(args)
    elif args.command == "generate":
        cmd_generate(args)


if __name__ == "__main__":
    main()

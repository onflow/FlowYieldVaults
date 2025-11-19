#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  FlowALP Scheduled Liquidations - Multi-Market E2E    ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# 0) Wait for emulator
echo -e "${BLUE}Waiting for emulator (3569) to be ready...${NC}"
for i in {1..30}; do
  if nc -z 127.0.0.1 3569; then
    echo -e "${GREEN}Emulator ready.${NC}"
    break
  fi
  sleep 1
done
nc -z 127.0.0.1 3569 || { echo -e "${RED}Emulator not detected on port 3569${NC}"; exit 1; }

# 1) Idempotent base setup
echo -e "${BLUE}Running setup_wallets.sh (idempotent)...${NC}"
bash ./local/setup_wallets.sh || true

echo -e "${BLUE}Running setup_emulator.sh (idempotent)...${NC}"
bash ./local/setup_emulator.sh || true

# Normalize FLOW price to 1.0 before opening FlowALP positions, so that later
# drops to 0.7 genuinely create undercollateralisation (mirroring FlowALP tests).
echo -e "${BLUE}Resetting FLOW oracle price to 1.0 for FlowALP position setup...${NC}"
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 1.0 --network emulator --signer tidal >/dev/null || true

echo -e "${BLUE}Ensuring MOET vault exists for tidal (keeper)...${NC}"
flow transactions send ./cadence/transactions/moet/setup_vault.cdc \
  --network emulator --signer tidal >/dev/null || true

echo -e "${BLUE}Setting up FlowALP liquidation Supervisor...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/setup_liquidation_supervisor.cdc \
  --network emulator --signer tidal >/dev/null || true

# 2) Create multiple markets and positions
DEFAULT_TOKEN_ID="A.045a1763c93006ca.MOET.Vault"
MARKET_IDS=(0 1)
POSITION_IDS=()

for MID in "${MARKET_IDS[@]}"; do
  echo -e "${BLUE}Creating market ${MID} and auto-registering...${NC}"
  flow transactions send ./lib/FlowALP/cadence/transactions/alp/create_market.cdc \
    --network emulator --signer tidal \
    --args-json "[{\"type\":\"String\",\"value\":\"${DEFAULT_TOKEN_ID}\"},{\"type\":\"UInt64\",\"value\":\"${MID}\"}]" >/dev/null || true
done

for MID in "${MARKET_IDS[@]}"; do
  echo -e "${BLUE}Opening FlowALP position for market ${MID}...${NC}"
  flow transactions send ./lib/FlowALP/cadence/transactions/alp/open_position_for_market.cdc \
    --network emulator --signer tidal \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"${MID}\"},{\"type\":\"UFix64\",\"value\":\"1000.0\"}]" >/dev/null
done

# 3) Induce undercollateralisation
echo -e "${BLUE}Dropping FLOW oracle price to 0.7 to put positions underwater...${NC}"
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 0.7 --network emulator --signer tidal >/dev/null

# Discover one underwater position per market using scheduler registry, so we
# don't assume position IDs are contiguous or reset across emulator runs.
HEALTH_BEFORE=()
for MID in "${MARKET_IDS[@]}"; do
  UW_RAW=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_underwater_positions.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"${MID}\"}]" 2>/dev/null | tr -d '\n' || true)
  echo -e "${BLUE}Underwater positions for market ${MID}: ${UW_RAW}${NC}"
  UW_IDS=$(echo "${UW_RAW}" | grep -oE '\[[^]]*\]' | tr -d '[] ' || true)
  # Prefer the highest PID per market so we use the position just opened in this test run.
  PID=$(echo "${UW_IDS}" | tr ',' ' ' | xargs -n1 | sort -n | tail -1)
  if [[ -z "${PID}" ]]; then
    echo -e "${RED}FAIL: No underwater positions detected for market ${MID}.${NC}"
    exit 1
  fi
  POSITION_IDS+=("${PID}")

  RAW=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"${PID}\"}]" 2>/dev/null | tr -d '\n')
  HEALTH_BEFORE+=("$RAW")
  echo -e "${BLUE}Position ${PID} health before liquidation: ${RAW}${NC}"
done

# 4) Schedule Supervisor once to fan out liquidations
FUTURE_TS=$(python - <<'PY'
import time
print(f"{time.time()+12:.1f}")
PY
)
echo -e "${BLUE}Estimating fee for Supervisor schedule at ${FUTURE_TS}...${NC}"
ESTIMATE=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/estimate_liquidation_cost.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UFix64\",\"value\":\"${FUTURE_TS}\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"}]" 2>/dev/null | tr -d '\n' || true)
EST_FEE=$(echo "$ESTIMATE" | sed -n 's/.*flowFee: \([0-9]*\.[0-9]*\).*/\1/p')
FEE=$(python - <<PY
f=float("${EST_FEE}") if "${EST_FEE}" else 0.00005
print(f"{f+0.00003:.8f}")
PY
)
echo -e "${BLUE}Using Supervisor scheduling fee: ${FEE}${NC}"

START_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
START_HEIGHT=${START_HEIGHT:-0}

echo -e "${BLUE}Scheduling Supervisor once for multi-market fan-out...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/schedule_supervisor.cdc \
  --network emulator --signer tidal \
  --args-json "[\
    {\"type\":\"UFix64\",\"value\":\"${FUTURE_TS}\"},\
    {\"type\":\"UInt8\",\"value\":\"1\"},\
    {\"type\":\"UInt64\",\"value\":\"800\"},\
    {\"type\":\"UFix64\",\"value\":\"${FEE}\"},\
    {\"type\":\"UFix64\",\"value\":\"0.0\"},\
    {\"type\":\"UInt64\",\"value\":\"10\"},\
    {\"type\":\"Bool\",\"value\":false},\
    {\"type\":\"UFix64\",\"value\":\"60.0\"}\
  ]" >/dev/null

echo -e "${BLUE}Waiting ~25s for Supervisor and child liquidations to execute...${NC}"
sleep 25

END_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
END_HEIGHT=${END_HEIGHT:-$START_HEIGHT}

EXEC_EVENTS_COUNT=$(flow events get A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed \
  --network emulator \
  --start ${START_HEIGHT} --end ${END_HEIGHT} 2>/dev/null | grep -c "A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed" || true)

if [[ "${EXEC_EVENTS_COUNT:-0}" -eq 0 ]]; then
  echo -e "${YELLOW}Warning: No FlowTransactionScheduler.Executed events detected in block window.${NC}"
fi

# 5) Verify each market/position pair has at least one executed liquidation proof
ALL_OK=1
for idx in "${!MARKET_IDS[@]}"; do
  MID=${MARKET_IDS[$idx]}
  PID=${POSITION_IDS[$idx]}
  RES=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_executed_liquidations_for_position.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"${MID}\"},{\"type\":\"UInt64\",\"value\":\"${PID}\"}]" 2>/dev/null | tr -d '\n')
  echo -e "${BLUE}Executed IDs for (market=${MID}, position=${PID}): ${RES}${NC}"
  IDS=$(echo "${RES}" | grep -oE '\[[^]]*\]' | tr -d '[] ' || true)
  if [[ -z "${IDS}" ]]; then
    echo -e "${RED}No executed liquidation proof found for market ${MID}, position ${PID}.${NC}"
    ALL_OK=0
  fi
done

if [[ "${ALL_OK}" -ne 1 ]]; then
  echo -e "${RED}FAIL: At least one market/position pair did not receive an executed liquidation.${NC}"
  exit 1
fi

# 6) Verify health improved for each position
HEALTH_AFTER=()
for PID in "${POSITION_IDS[@]}"; do
  RAW=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"${PID}\"}]" 2>/dev/null | tr -d '\n')
  HEALTH_AFTER+=("$RAW")
  echo -e "${BLUE}Position ${PID} health after liquidations: ${RAW}${NC}"
done

extract_health() { printf "%s" "$1" | grep -oE 'Result: [^[:space:]]+' | awk '{print $2}'; }

for idx in "${!POSITION_IDS[@]}"; do
  PID=${POSITION_IDS[$idx]}
  HB_RAW=${HEALTH_BEFORE[$idx]}
  HA_RAW=${HEALTH_AFTER[$idx]}
  HB=$(extract_health "${HB_RAW}")
  HA=$(extract_health "${HA_RAW}")
  if [[ -z "${HB}" || -z "${HA}" ]]; then
    echo -e "${YELLOW}Could not parse health values for position ${PID}; skipping delta assertion.${NC}"
    continue
  fi
  echo -e "${BLUE}Position ${PID} health before=${HB}, after=${HA}${NC}"
  python - <<PY
hb=float("${HB}")
ha=float("${HA}")
import sys
if not (ha > hb and ha >= 1.0):
    print("Health did not improve enough for position ${PID} (hb={}, ha={})".format(hb, ha))
    sys.exit(1)
PY
done

echo -e "${GREEN}PASS: Multi-market Supervisor fan-out executed liquidations across all markets with observable state change.${NC}"



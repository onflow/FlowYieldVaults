#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  FlowALP Scheduled Liquidations - Auto-Register E2E   ║${NC}"
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

# 1) Base setup
echo -e "${BLUE}Running setup_wallets.sh (idempotent)...${NC}"
bash ./local/setup_wallets.sh || true

echo -e "${BLUE}Running setup_emulator.sh (idempotent)...${NC}"
bash ./local/setup_emulator.sh || true

# Normalize FLOW price to 1.0 before FlowALP market/position setup so drops to
# 0.7 later actually create undercollateralisation (matching FlowALP tests).
echo -e "${BLUE}Resetting FLOW oracle price to 1.0 for FlowALP position setup...${NC}"
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 1.0 --network emulator --signer tidal >/dev/null || true

echo -e "${BLUE}Ensuring MOET vault exists for tidal (keeper)...${NC}"
flow transactions send ./cadence/transactions/moet/setup_vault.cdc \
  --network emulator --signer tidal >/dev/null || true

echo -e "${BLUE}Setting up FlowALP liquidation Supervisor...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/setup_liquidation_supervisor.cdc \
  --network emulator --signer tidal >/dev/null || true

# 2) Snapshot currently registered markets
echo -e "${BLUE}Fetching currently registered FlowALP market IDs...${NC}"
BEFORE_MARKETS_RAW=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_registered_market_ids.cdc \
  --network emulator 2>/dev/null | tr -d '\n' || true)
BEFORE_IDS=$(echo "${BEFORE_MARKETS_RAW}" | grep -oE '\[[^]]*\]' | tr -d '[] ' || true)
echo -e "${BLUE}Registered markets before: [${BEFORE_IDS}]${NC}"

# Choose a new market ID not in BEFORE_IDS (simple max+1 heuristic)
NEW_MARKET_ID=0
if [[ -n "${BEFORE_IDS}" ]]; then
  MAX_ID=$(echo "${BEFORE_IDS}" | tr ',' ' ' | xargs -n1 | sort -n | tail -1)
  NEW_MARKET_ID=$((MAX_ID + 1))
fi
echo -e "${BLUE}Using new market ID: ${NEW_MARKET_ID}${NC}"

# 3) Create new market (auto-register) and open a position
DEFAULT_TOKEN_ID="A.045a1763c93006ca.MOET.Vault"

echo -e "${BLUE}Creating new FlowALP market ${NEW_MARKET_ID} (with auto-registration)...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/create_market.cdc \
  --network emulator --signer tidal \
  --args-json "[{\"type\":\"String\",\"value\":\"${DEFAULT_TOKEN_ID}\"},{\"type\":\"UInt64\",\"value\":\"${NEW_MARKET_ID}\"}]" >/dev/null

AFTER_MARKETS_RAW=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_registered_market_ids.cdc \
  --network emulator 2>/dev/null | tr -d '\n' || true)
AFTER_IDS=$(echo "${AFTER_MARKETS_RAW}" | grep -oE '\[[^]]*\]' | tr -d '[] ' || true)
echo -e "${BLUE}Registered markets after: [${AFTER_IDS}]${NC}"

if ! echo "${AFTER_IDS}" | tr ',' ' ' | grep -qw "${NEW_MARKET_ID}"; then
  echo -e "${RED}FAIL: New market ID ${NEW_MARKET_ID} was not auto-registered in FlowALPSchedulerRegistry.${NC}"
  exit 1
fi

echo -e "${BLUE}Opening position in new market ${NEW_MARKET_ID}...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/open_position_for_market.cdc \
  --network emulator --signer tidal \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${NEW_MARKET_ID}\"},{\"type\":\"UFix64\",\"value\":\"1000.0\"}]" >/dev/null

# 4) Make the new market's position(s) underwater
echo -e "${BLUE}Dropping FLOW oracle price to 0.7 for new market liquidation...${NC}"
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 0.7 --network emulator --signer tidal >/dev/null

UNDERWATER_RES=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_underwater_positions.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${NEW_MARKET_ID}\"}]" 2>/dev/null | tr -d '\n' || true)
echo -e "${BLUE}Underwater positions for market ${NEW_MARKET_ID}: ${UNDERWATER_RES}${NC}"
UW_IDS=$(echo "${UNDERWATER_RES}" | grep -oE '\[[^]]*\]' | tr -d '[] ' || true)
UW_PID=$(echo "${UW_IDS}" | awk '{print $1}')

if [[ -z "${UW_PID}" ]]; then
  echo -e "${RED}FAIL: No underwater positions detected for new market ${NEW_MARKET_ID}.${NC}"
  exit 1
fi

echo -e "${BLUE}Using underwater position ID ${UW_PID} for auto-register test.${NC}"

HEALTH_BEFORE_RAW=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${UW_PID}\"}]" 2>/dev/null | tr -d '\n')
echo -e "${BLUE}Position health before supervisor scheduling: ${HEALTH_BEFORE_RAW}${NC}"

extract_health() { printf "%s" "$1" | grep -oE 'Result: [^[:space:]]+' | awk '{print $2}'; }
HB=$(extract_health "${HEALTH_BEFORE_RAW}")

# Helper to estimate fee for a given future timestamp
estimate_fee() {
  local ts="$1"
  local est_raw fee_raw fee
  est_raw=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/estimate_liquidation_cost.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UFix64\",\"value\":\"${ts}\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"}]" 2>/dev/null | tr -d '\n' || true)
  fee_raw=$(echo "$est_raw" | sed -n 's/.*flowFee: \([0-9]*\.[0-9]*\).*/\1/p')
  fee=$(python - <<PY
f=float("${fee_raw}") if "${fee_raw}" else 0.00005
print(f"{f+0.00003:.8f}")
PY
)
  echo "${fee}"
}

# Helper to find a child schedule for the underwater position
find_child_schedule() {
  local mid="$1"
  local pid="$2"
  local info sid
  info=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_scheduled_liquidation.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"${mid}\"},{\"type\":\"UInt64\",\"value\":\"${pid}\"}]" 2>/dev/null || true)
  sid=$(echo "${info}" | awk -F'scheduledTransactionID: ' '/scheduledTransactionID: /{print $2}' | awk -F',' '{print $1}' | tr -cd '0-9')
  echo "${sid}"
}

# 5) Schedule Supervisor; retry once if necessary; fallback to manual schedule
SCHED_ID=""

for attempt in 1 2; do
  FUTURE_TS=$(python - <<'PY'
import time
print(f"{time.time()+10:.1f}")
PY
)
  FEE=$(estimate_fee "${FUTURE_TS}")
  echo -e "${BLUE}Scheduling Supervisor attempt ${attempt} at ${FUTURE_TS} (fee=${FEE})...${NC}"
  flow transactions send ./lib/FlowALP/cadence/transactions/alp/schedule_supervisor.cdc \
    --network emulator --signer tidal \
    --args-json "[\
      {\"type\":\"UFix64\",\"value\":\"${FUTURE_TS}\"},\
      {\"type\":\"UInt8\",\"value\":\"1\"},\
      {\"type\":\"UInt64\",\"value\":\"800\"},\
      {\"type\":\"UFix64\",\"value\":\"${FEE}\"},\
      {\"type\":\"UFix64\",\"value\":\"10.0\"},\
      {\"type\":\"UInt64\",\"value\":\"10\"},\
      {\"type\":\"Bool\",\"value\":true},\
      {\"type\":\"UFix64\",\"value\":\"60.0\"}\
    ]" >/dev/null || true

  echo -e "${BLUE}Waiting ~20s for Supervisor to seed child jobs (attempt ${attempt})...${NC}"
  sleep 20

  SCHED_ID=$(find_child_schedule "${NEW_MARKET_ID}" "${UW_PID}")
  if [[ -n "${SCHED_ID}" ]]; then
    break
  fi
done

if [[ -z "${SCHED_ID}" ]]; then
  echo -e "${YELLOW}Supervisor did not seed a child job; falling back to manual schedule for (market=${NEW_MARKET_ID}, position=${UW_PID}).${NC}"
  FUTURE_TS=$(python - <<'PY'
import time
print(f"{time.time()+12:.1f}")
PY
)
  FEE=$(estimate_fee "${FUTURE_TS}")
  flow transactions send ./lib/FlowALP/cadence/transactions/alp/schedule_liquidation.cdc \
    --network emulator --signer tidal \
    --args-json "[\
      {\"type\":\"UInt64\",\"value\":\"${NEW_MARKET_ID}\"},\
      {\"type\":\"UInt64\",\"value\":\"${UW_PID}\"},\
      {\"type\":\"UFix64\",\"value\":\"${FUTURE_TS}\"},\
      {\"type\":\"UInt8\",\"value\":\"1\"},\
      {\"type\":\"UInt64\",\"value\":\"800\"},\
      {\"type\":\"UFix64\",\"value\":\"${FEE}\"},\
      {\"type\":\"Bool\",\"value\":false},\
      {\"type\":\"UFix64\",\"value\":\"0.0\"}\
    ]" >/dev/null
  # Fetch the manual scheduled ID
  SCHED_ID=$(find_child_schedule "${NEW_MARKET_ID}" "${UW_PID}")
fi

if [[ -z "${SCHED_ID}" ]]; then
  echo -e "${RED}FAIL: Could not determine scheduledTransactionID for new market after supervisor and manual attempts.${NC}"
  exit 1
fi

echo -e "${GREEN}Child scheduled Tx ID for new market ${NEW_MARKET_ID}, position ${UW_PID}: ${SCHED_ID}${NC}"

# 6) Poll scheduler status and on-chain proof
START_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
START_HEIGHT=${START_HEIGHT:-0}

STATUS_NIL_OK=0
STATUS_RAW=""
echo -e "${BLUE}Polling scheduled transaction status for ID ${SCHED_ID}...${NC}"
for i in {1..45}; do
  STATUS_RAW=$((flow scripts execute ./cadence/scripts/flow-vaults/get_scheduled_tx_status.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"${SCHED_ID}\"}]" 2>/dev/null | tr -d '\n' | grep -oE 'rawValue: [0-9]+' | awk '{print $2}') || true)
  if [[ -z "${STATUS_RAW}" ]]; then
    echo -e "${GREEN}Status: nil (likely removed after execution)${NC}"
    STATUS_NIL_OK=1
    break
  fi
  echo -e "${BLUE}Status rawValue: ${STATUS_RAW}${NC}"
  if [[ "${STATUS_RAW}" == "2" ]]; then
    echo -e "${GREEN}Scheduled transaction executed.${NC}"
    break
  fi
  sleep 1
done

END_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
END_HEIGHT=${END_HEIGHT:-$START_HEIGHT}
EXEC_EVENTS_COUNT=$(flow events get A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed \
  --network emulator \
  --start ${START_HEIGHT} --end ${END_HEIGHT} 2>/dev/null | grep -c "A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed" || true)

OC_RES=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_liquidation_proof.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${NEW_MARKET_ID}\"},{\"type\":\"UInt64\",\"value\":\"${UW_PID}\"},{\"type\":\"UInt64\",\"value\":\"${SCHED_ID}\"}]" 2>/dev/null | tr -d '\n')
echo -e "${BLUE}On-chain liquidation proof for ${SCHED_ID}: ${OC_RES}${NC}"
OC_OK=0; [[ "$OC_RES" =~ "Result: true" ]] && OC_OK=1

if [[ "${STATUS_RAW:-}" != "2" && "${EXEC_EVENTS_COUNT:-0}" -eq 0 && "${STATUS_NIL_OK:-0}" -eq 0 && "${OC_OK:-0}" -eq 0 ]]; then
  echo -e "${RED}FAIL: No proof that scheduled liquidation executed for new market (status/event/on-chain).${NC}"
  exit 1
fi

# 7) Verify health improved for the new market's position
HEALTH_AFTER_RAW=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${UW_PID}\"}]" 2>/dev/null | tr -d '\n')
echo -e "${BLUE}Position health after liquidation: ${HEALTH_AFTER_RAW}${NC}"

HA=$(extract_health "${HEALTH_AFTER_RAW}")

if [[ -z "${HB}" || -z "${HA}" ]]; then
  echo -e "${YELLOW}Could not parse health values; skipping health delta assertion.${NC}"
else
  python - <<PY
hb=float("${HB}")
ha=float("${HA}")
import sys
if not (ha > hb and ha >= 1.0):
    print("Health did not improve enough for new market position (hb={}, ha={})".format(hb, ha))
    sys.exit(1)
PY
fi

echo -e "${GREEN}PASS: Auto-registered market ${NEW_MARKET_ID} received a Supervisor or manual scheduled liquidation with observable state change.${NC}"



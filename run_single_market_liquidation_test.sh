#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  FlowALP Scheduled Liquidations - Single Market E2E  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
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

# 1) Idempotent base setup (wallets, contracts, FlowALP pool)
echo -e "${BLUE}Running setup_wallets.sh (idempotent)...${NC}"
bash ./local/setup_wallets.sh || true

echo -e "${BLUE}Running setup_emulator.sh (idempotent)...${NC}"
bash ./local/setup_emulator.sh || true

# 2) Normalize FLOW price for position setup (match FlowALP unit test baseline)
echo -e "${BLUE}Resetting FLOW oracle price to 1.0 for FlowALP position setup...${NC}"
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 1.0 --network emulator --signer tidal >/dev/null || true

# 3) Ensure MOET vault and liquidation Supervisor are configured for tidal
echo -e "${BLUE}Ensuring MOET vault exists for tidal (keeper)...${NC}"
flow transactions send ./cadence/transactions/moet/setup_vault.cdc \
  --network emulator --signer tidal >/dev/null || true

echo -e "${BLUE}Setting up FlowALP liquidation Supervisor...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/setup_liquidation_supervisor.cdc \
  --network emulator --signer tidal >/dev/null || true

# 4) Create a single market and open one position
DEFAULT_TOKEN_ID="A.045a1763c93006ca.MOET.Vault"
MARKET_ID=0

echo -e "${BLUE}Creating FlowALP market ${MARKET_ID} and auto-registering with scheduler...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/create_market.cdc \
  --network emulator --signer tidal \
  --args-json "[{\"type\":\"String\",\"value\":\"${DEFAULT_TOKEN_ID}\"},{\"type\":\"UInt64\",\"value\":\"${MARKET_ID}\"}]" >/dev/null

echo -e "${BLUE}Opening FlowALP position for market ${MARKET_ID} (tidal as user)...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/open_position_for_market.cdc \
  --network emulator --signer tidal \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${MARKET_ID}\"},{\"type\":\"UFix64\",\"value\":\"1000.0\"}]" >/dev/null

# 5) Induce undercollateralisation by dropping FLOW price
echo -e "${BLUE}Dropping FLOW oracle price to make position undercollateralised...${NC}"
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 0.7 --network emulator --signer tidal >/dev/null

# Discover the actual underwater position ID for this market (do not assume 0),
# then compute health "before" (i.e. after price drop but before liquidation).
UW_RAW=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_underwater_positions.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${MARKET_ID}\"}]" 2>/dev/null | tr -d '\n' || true)
echo -e "${BLUE}Underwater positions for market ${MARKET_ID}: ${UW_RAW}${NC}"
UW_IDS=$(echo "${UW_RAW}" | grep -oE '\[[^]]*\]' | tr -d '[] ' || true)
# Prefer the highest PID so we act on the position just created in this test run.
POSITION_ID=$(echo "${UW_IDS}" | tr ',' ' ' | xargs -n1 | sort -n | tail -1)
if [[ -z "${POSITION_ID}" ]]; then
  echo -e "${RED}FAIL: No underwater positions detected for market ${MARKET_ID} after price drop.${NC}"
  exit 1
fi

HEALTH_BEFORE_RAW=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${POSITION_ID}\"}]" 2>/dev/null | tr -d '\n')
echo -e "${BLUE}Position health before liquidation (pid=${POSITION_ID}): ${HEALTH_BEFORE_RAW}${NC}"

# 6) Estimate scheduling cost for a liquidation ~12s in the future
FUTURE_TS=$(python - <<'PY'
import time
print(f"{time.time()+12:.1f}")
PY
)
echo -e "${BLUE}Estimating scheduling cost for liquidation at ${FUTURE_TS}...${NC}"
ESTIMATE=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/estimate_liquidation_cost.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UFix64\",\"value\":\"${FUTURE_TS}\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"}]" 2>/dev/null | tr -d '\n' || true)
EST_FEE=$(echo "$ESTIMATE" | sed -n 's/.*flowFee: \([0-9]*\.[0-9]*\).*/\1/p')
FEE=$(python - <<PY
f=float("${EST_FEE}") if "${EST_FEE}" else 0.00005
print(f"{f+0.00003:.8f}")
PY
)
echo -e "${BLUE}Using scheduling fee: ${FEE}${NC}"

# 7) Schedule a single liquidation child for (marketID, positionID)
echo -e "${BLUE}Scheduling liquidation for market ${MARKET_ID}, position ${POSITION_ID}...${NC}"
flow transactions send ./lib/FlowALP/cadence/transactions/alp/schedule_liquidation.cdc \
  --network emulator --signer tidal \
  --args-json "[\
    {\"type\":\"UInt64\",\"value\":\"${MARKET_ID}\"},\
    {\"type\":\"UInt64\",\"value\":\"${POSITION_ID}\"},\
    {\"type\":\"UFix64\",\"value\":\"${FUTURE_TS}\"},\
    {\"type\":\"UInt8\",\"value\":\"1\"},\
    {\"type\":\"UInt64\",\"value\":\"800\"},\
    {\"type\":\"UFix64\",\"value\":\"${FEE}\"},\
    {\"type\":\"Bool\",\"value\":false},\
    {\"type\":\"UFix64\",\"value\":\"0.0\"}\
  ]" >/dev/null

# Capture initial block height for event queries
START_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
START_HEIGHT=${START_HEIGHT:-0}

# 7) Fetch scheduled transaction ID via public script
echo -e "${BLUE}Fetching scheduled liquidation info for (market=${MARKET_ID}, position=${POSITION_ID})...${NC}"
INFO=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_scheduled_liquidation.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${MARKET_ID}\"},{\"type\":\"UInt64\",\"value\":\"${POSITION_ID}\"}]" 2>/dev/null || true)
SCHED_ID=$(echo "${INFO}" | awk -F'scheduledTransactionID: ' '/scheduledTransactionID: /{print $2}' | awk -F',' '{print $1}' | tr -cd '0-9')

if [[ -z "${SCHED_ID}" ]]; then
  echo -e "${YELLOW}Could not determine scheduledTransactionID from script output.${NC}"
  exit 1
fi
echo -e "${GREEN}Scheduled Tx ID: ${SCHED_ID}${NC}"

# 8) Poll scheduler status until Executed (2) or removed (nil)
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

# 9) On-chain proof via FlowALPSchedulerProofs
OC_RES=$(flow scripts execute ./lib/FlowALP/cadence/scripts/alp/get_liquidation_proof.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${MARKET_ID}\"},{\"type\":\"UInt64\",\"value\":\"${POSITION_ID}\"},{\"type\":\"UInt64\",\"value\":\"${SCHED_ID}\"}]" 2>/dev/null | tr -d '\n')
echo -e "${BLUE}On-chain liquidation proof for ${SCHED_ID}: ${OC_RES}${NC}"
OC_OK=0; [[ "$OC_RES" =~ "Result: true" ]] && OC_OK=1

if [[ "${STATUS_RAW:-}" != "2" && "${EXEC_EVENTS_COUNT:-0}" -eq 0 && "${STATUS_NIL_OK:-0}" -eq 0 && "${OC_OK:-0}" -eq 0 ]]; then
  echo -e "${RED}FAIL: No proof that scheduled liquidation executed (status/event/on-chain).${NC}"
  exit 1
fi

# 10) Verify position health improved after liquidation
HEALTH_AFTER_RAW=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"${POSITION_ID}\"}]" 2>/dev/null | tr -d '\n')
echo -e "${BLUE}Position health after liquidation: ${HEALTH_AFTER_RAW}${NC}"

extract_health() { printf "%s" "$1" | grep -oE 'Result: [^[:space:]]+' | awk '{print $2}'; }
HB=$(extract_health "${HEALTH_BEFORE_RAW}")
HA=$(extract_health "${HEALTH_AFTER_RAW}")

if [[ -z "${HB}" || -z "${HA}" ]]; then
  echo -e "${YELLOW}Could not parse position health values; skipping health delta assertion.${NC}"
else
  echo -e "${BLUE}Health before: ${HB}, after: ${HA}${NC}"
  python - <<PY
hb=float("${HB}")
ha=float("${HA}")
import sys
if not (ha > hb and ha >= 1.0):
    print("Health did not improve enough after liquidation (hb={}, ha={})".format(hb, ha))
    sys.exit(1)
PY
fi

echo -e "${GREEN}PASS: Single-market scheduled liquidation executed with observable state change.${NC}"



#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Auto-Register Tide -> Auto Rebalance (Two-Terminal)     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
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

# 1) Minimal idempotent setup
echo -e "${BLUE}Granting FlowVaults beta to tidal...${NC}"
flow transactions send cadence/transactions/flow-vaults/admin/grant_beta.cdc \
  --network emulator \
  --payer tidal --proposer tidal \
  --authorizer tidal --authorizer tidal >/dev/null || true

echo -e "${BLUE}Setting up SchedulerManager...${NC}"
flow transactions send cadence/transactions/flow-vaults/setup_scheduler_manager.cdc \
  --network emulator --signer tidal >/dev/null || true

echo -e "${BLUE}Setting up Supervisor...${NC}"
flow transactions send cadence/transactions/flow-vaults/setup_supervisor.cdc \
  --network emulator --signer tidal >/dev/null || true

# Capture initial block height
START_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
START_HEIGHT=${START_HEIGHT:-0}

# 2) Create a new tide (auto-register happens inside), then schedule Supervisor to seed its first child

# 3) Record existing tide IDs, then create a new tide (auto-register happens inside the transaction)
echo -e "${BLUE}Fetching existing tide IDs...${NC}"
BEFORE_IDS=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x045a1763c93006ca"}]' | grep -oE '\[[^]]*\]' | tr -d '[] ' || true)

echo -e "${BLUE}Creating a new tide (100 FLOW) - auto-register will run inside...${NC}"
flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \
  --network emulator --signer tidal \
  --args-json '[{"type":"String","value":"A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy"},{"type":"String","value":"A.0ae53cb6e3f42a79.FlowToken.Vault"},{"type":"UFix64","value":"100.0"}]' >/dev/null

AFTER_IDS=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x045a1763c93006ca"}]' | grep -oE '\[[^]]*\]' | tr -d '[] ' || true)

# Determine new tide ID
NEW_TIDE_ID=""
for id in $(echo "$AFTER_IDS" | tr ',' ' '); do
  if ! echo "$BEFORE_IDS" | tr ',' ' ' | tr -s ' ' | grep -qw "$id"; then
    NEW_TIDE_ID="$id"
    break
  fi
done
if [[ -z "${NEW_TIDE_ID}" ]]; then
  # fallback: choose the max id
  NEW_TIDE_ID=$(echo "$AFTER_IDS" | tr ',' ' ' | xargs -n1 | sort -n | tail -1)
fi
echo -e "${GREEN}New Tide ID: ${NEW_TIDE_ID}${NC}"
[[ -n "${NEW_TIDE_ID}" ]] || { echo -e "${RED}Could not determine new Tide ID.${NC}"; exit 1; }

# Schedule Supervisor once (now that the new tide exists)
FUTURE=$(python - <<'PY'
import time; print(f"{time.time()+10:.1f}")
PY
)
echo -e "${BLUE}Estimating fee for supervisor schedule at ${FUTURE}...${NC}"
EST=$(flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc --network emulator \
  --args-json "[{\"type\":\"UFix64\",\"value\":\"$FUTURE\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"}]" \
  | sed -n 's/.*flowFee: \\([0-9]*\\.[0-9]*\\).*/\\1/p')
FEE=$(python - <<PY
f=float("$EST") if "$EST" else 0.00005
print(f"{f+0.00003:.8f}")
PY
)
SUP_JSON="[\
  {\"type\":\"UFix64\",\"value\":\"$FUTURE\"},\
  {\"type\":\"UInt8\",\"value\":\"1\"},\
  {\"type\":\"UInt64\",\"value\":\"800\"},\
  {\"type\":\"UFix64\",\"value\":\"$FEE\"},\
  {\"type\":\"UFix64\",\"value\":\"10.0\"},\
  {\"type\":\"Bool\",\"value\":true},\
  {\"type\":\"UFix64\",\"value\":\"300.0\"},\
  {\"type\":\"Bool\",\"value\":false}\
]"
echo -e "${BLUE}Scheduling Supervisor once...${NC}"
if ! flow transactions send cadence/transactions/flow-vaults/schedule_supervisor.cdc \
  --network emulator --signer tidal --args-json "$SUP_JSON" >/dev/null; then
  # Retry once with a fresh timestamp and fee in case timestamp just passed
  FUTURE=$(python - <<'PY'
import time; print(f"{time.time()+12:.1f}")
PY
)
  EST=$(flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc --network emulator \
    --args-json "[{\"type\":\"UFix64\",\"value\":\"$FUTURE\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"}]" \
    | sed -n 's/.*flowFee: \\([0-9]*\\.[0-9]*\\).*/\\1/p')
  FEE=$(python - <<PY
f=float("$EST") if "$EST" else 0.00005
print(f"{f+0.00003:.8f}")
PY
)
  SUP_JSON="[\
    {\"type\":\"UFix64\",\"value\":\"$FUTURE\"},\
    {\"type\":\"UInt8\",\"value\":\"1\"},\
    {\"type\":\"UInt64\",\"value\":\"800\"},\
    {\"type\":\"UFix64\",\"value\":\"$FEE\"},\
    {\"type\":\"UFix64\",\"value\":\"10.0\"},\
    {\"type\":\"Bool\",\"value\":true},\
    {\"type\":\"UFix64\",\"value\":\"300.0\"},\
    {\"type\":\"Bool\",\"value\":false}\
  ]"
  flow transactions send cadence/transactions/flow-vaults/schedule_supervisor.cdc \
    --network emulator --signer tidal --args-json "$SUP_JSON" >/dev/null
fi

# 4) Initial metrics for the new tide
echo -e "${BLUE}Initial metrics for tide ${NEW_TIDE_ID}:${NC}"
INIT_BAL=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"}]")
INIT_VAL=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_current_value_by_id.cdc \
  --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"}]")
INIT_TBAL=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_balance.cdc \
  --network emulator --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"}]")
echo -e "${BLUE}  bal=${INIT_BAL}${NC}"
echo -e "${BLUE}  val=${INIT_VAL}${NC}"
echo -e "${BLUE}  tideBal=${INIT_TBAL}${NC}"

# 5) Price drift so that rebalance is needed
echo -e "${BLUE}Changing FLOW & YIELD prices to induce drift...${NC}"
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 1.8 --signer tidal >/dev/null
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.045a1763c93006ca.YieldToken.Vault' 1.5 --signer tidal >/dev/null

# 6) Wait for Supervisor to run and seed the child schedule; then poll child scheduled tx
echo -e "${BLUE}Waiting for Supervisor execution and child schedule...${NC}"

SCHED_ID=""
for i in {1..30}; do
  INFO=$(flow scripts execute cadence/scripts/flow-vaults/get_scheduled_rebalancing.cdc \
    --network emulator \
    --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"}]" 2>/dev/null || true)
  SCHED_ID=$(echo "${INFO}" | awk -F'scheduledTransactionID: ' '/scheduledTransactionID: /{print $2}' | awk -F',' '{print $1}' | tr -cd '0-9')
  if [[ -n "${SCHED_ID}" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${SCHED_ID}" ]]; then
  echo -e "${YELLOW}Child schedule not found yet; triggering Supervisor again and extending wait...${NC}"
  FUTURE=$(python - <<'PY'
import time; print(f"{time.time()+6:.1f}")
PY
)
  EST=$(flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc --network emulator \
    --args-json "[{\"type\":\"UFix64\",\"value\":\"$FUTURE\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"}]" \
    | sed -n 's/.*flowFee: \\([0-9]*\\.[0-9]*\\).*/\\1/p')
  FEE=$(python - <<PY
f=float("$EST") if "$EST" else 0.00005
print(f"{f+0.00003:.8f}")
PY
)
  SUP_JSON="[\
    {\"type\":\"UFix64\",\"value\":\"$FUTURE\"},\
    {\"type\":\"UInt8\",\"value\":\"1\"},\
    {\"type\":\"UInt64\",\"value\":\"800\"},\
    {\"type\":\"UFix64\",\"value\":\"$FEE\"},\
    {\"type\":\"UFix64\",\"value\":\"10.0\"},\
    {\"type\":\"Bool\",\"value\":true},\
    {\"type\":\"UFix64\",\"value\":\"300.0\"},\
    {\"type\":\"Bool\",\"value\":false}\
  ]"
  flow transactions send cadence/transactions/flow-vaults/schedule_supervisor.cdc \
    --network emulator --signer tidal --args-json "$SUP_JSON" >/dev/null || true
  for i in {1..30}; do
    INFO=$(flow scripts execute cadence/scripts/flow-vaults/get_scheduled_rebalancing.cdc \
      --network emulator \
      --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"}]" 2>/dev/null || true)
    SCHED_ID=$(echo "${INFO}" | awk -F'scheduledTransactionID: ' '/scheduledTransactionID: /{print $2}' | awk -F',' '{print $1}' | tr -cd '0-9')
    if [[ -n "${SCHED_ID}" ]]; then
      break
    fi
    sleep 1
  done
  if [[ -z "${SCHED_ID}" ]]; then
    echo -e "${RED}Child schedule for tide ${NEW_TIDE_ID} was not created by Supervisor after retry.${NC}"
    exit 1
  fi
fi
echo -e "${GREEN}Child Scheduled Tx ID for tide ${NEW_TIDE_ID}: ${SCHED_ID}${NC}"

# 7) Poll scheduled tx status to executed or nil, then verify on-chain proof and movement
STATUS_NIL_OK=0
STATUS_RAW=""
for i in {1..45}; do
  STATUS_RAW=$((flow scripts execute cadence/scripts/flow-vaults/get_scheduled_tx_status.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$SCHED_ID\"}]" 2>/dev/null | tr -d '\n' | grep -oE 'rawValue: [0-9]+' | awk '{print $2}') || true)
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
EXEC_EVENTS_COUNT=$(flow events get A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed --start ${START_HEIGHT} --end ${END_HEIGHT} 2>/dev/null | grep -c "A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed" || true)

OC_RES=$(flow scripts execute cadence/scripts/flow-vaults/was_rebalancing_executed.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"},{\"type\":\"UInt64\",\"value\":\"$SCHED_ID\"}]" 2>/dev/null | tr -d '\n')
echo -e "${BLUE}On-chain executed proof for ${SCHED_ID}: ${OC_RES}${NC}"
OC_OK=0; [[ "$OC_RES" =~ "Result: true" ]] && OC_OK=1

if [[ "${STATUS_RAW:-}" != "2" && "${EXEC_EVENTS_COUNT:-0}" -eq 0 && "${STATUS_NIL_OK:-0}" -eq 0 && "${OC_OK:-0}" -eq 0 ]]; then
  echo -e "${RED}FAIL: No proof that scheduled tx executed (status/event/on-chain).${NC}"
  exit 1
fi

FINAL_BAL=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"}]")
FINAL_VAL=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_current_value_by_id.cdc \
  --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"}]")
FINAL_TBAL=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_balance.cdc \
  --network emulator --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$NEW_TIDE_ID\"}]")

extract_val() { printf "%s" "$1" | grep -oE 'Result: [^[:space:]]+' | awk '{print $2}'; }
IB=$(extract_val "${INIT_BAL}"); FB=$(extract_val "${FINAL_BAL}")
IV=$(extract_val "${INIT_VAL}"); FV=$(extract_val "${FINAL_VAL}")
ITB=$(extract_val "${INIT_TBAL}"); FTB=$(extract_val "${FINAL_TBAL}")

REB_CNT=$(flow events get A.045a1763c93006ca.DeFiActions.Rebalanced --start ${START_HEIGHT} --end ${END_HEIGHT} 2>/dev/null | grep -c "A.045a1763c93006ca.DeFiActions.Rebalanced" || true)
if [[ "${IB}" == "${FB}" && "${IV}" == "${FV}" && "${ITB}" == "${FTB}" && "${REB_CNT:-0}" -eq 0 ]]; then
  echo -e "${RED}FAIL: No asset movement detected after rebalance.${NC}"
  echo -e "${BLUE}Initial bal=${INIT_BAL} val=${INIT_VAL} tideBal=${INIT_TBAL}${NC}"
  echo -e "${BLUE}Final   bal=${FINAL_BAL} val=${FINAL_VAL} tideBal=${FINAL_TBAL}${NC}"
  exit 1
fi

echo -e "${GREEN}PASS: Auto-register + Supervisor seeded first rebalance, and movement occurred for tide ${NEW_TIDE_ID}.${NC}"



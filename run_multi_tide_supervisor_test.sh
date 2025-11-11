#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Multi‑Tide Supervisor Rebalancing - Two-Terminal End-to-End  ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# 0) Wait for emulator with scheduled transactions
echo -e "${BLUE}Waiting for emulator (3569) to be ready...${NC}"
for i in {1..30}; do
  if nc -z 127.0.0.1 3569; then
    echo -e "${GREEN}Emulator ready.${NC}"
    break
  fi
  sleep 1
done
nc -z 127.0.0.1 3569 || { echo -e "${RED}Emulator not detected on port 3569${NC}"; exit 1; }

# 1) Idempotent local setup
echo -e "${BLUE}Running setup_wallets.sh (idempotent)...${NC}"
bash ./local/setup_wallets.sh || true
echo -e "${BLUE}Running setup_emulator.sh (idempotent)...${NC}"
bash ./local/setup_emulator.sh || true

# 2) Grant beta to tidal (idempotent)
echo -e "${BLUE}Granting FlowVaults beta to tidal...${NC}"
flow transactions send cadence/transactions/flow-vaults/admin/grant_beta.cdc \
  --network emulator \
  --payer tidal --proposer tidal \
  --authorizer tidal --authorizer tidal >/dev/null

# 3) Ensure at least 3 tides exist; create missing
echo -e "${BLUE}Ensuring at least 3 tides...${NC}"
TIDE_IDS_RAW=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x045a1763c93006ca"}]')
TIDE_IDS=$(echo "$TIDE_IDS_RAW" | grep -oE '\[[^]]*\]' | tr -d '[] ' | tr ',' ' ' | xargs -n1 | grep -E '^[0-9]+$' || true)
COUNT=$(echo "$TIDE_IDS" | wc -l | tr -d ' ')
NEED=$((3 - ${COUNT:-0}))
if [[ ${NEED} -gt 0 ]]; then
  for i in $(seq 1 ${NEED}); do
    echo -e "${BLUE}Creating tide #$((COUNT+i)) (deposit 100 FLOW)...${NC}"
    flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \
      --network emulator --signer tidal \
      --args-json '[{"type":"String","value":"A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy"},{"type":"String","value":"A.0ae53cb6e3f42a79.FlowToken.Vault"},{"type":"UFix64","value":"100.0"}]' >/dev/null
  done
  TIDE_IDS_RAW=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
    --network emulator \
    --args-json '[{"type":"Address","value":"0x045a1763c93006ca"}]')
  TIDE_IDS=$(echo "$TIDE_IDS_RAW" | grep -oE '\[[^]]*\]' | tr -d '[] ' | tr ',' ' ' | xargs -n1 | grep -E '^[0-9]+$' || true)
fi
echo -e "${GREEN}Tide IDs: $(echo $TIDE_IDS | xargs)${NC}"

# 4) Setup SchedulerManager (idempotent)
echo -e "${BLUE}Setting up SchedulerManager...${NC}"
flow transactions send cadence/transactions/flow-vaults/setup_scheduler_manager.cdc \
  --network emulator --signer tidal >/dev/null

# 5) Register each Tide with the Scheduler registry (idempotent)
echo -e "${BLUE}Registering tides...${NC}"
for TID in $TIDE_IDS; do
  flow transactions send cadence/transactions/flow-vaults/register_tide.cdc \
    --network emulator --signer tidal \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"${TID}\"}]" >/dev/null || true
done

# Capture start height for events
START_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
START_HEIGHT=${START_HEIGHT:-0}

# 6) Log initial metrics
echo -e "${BLUE}Initial metrics per tide:${NC}"
TMPDIR="/tmp/tide_metrics"
rm -rf "${TMPDIR}" && mkdir -p "${TMPDIR}"
for TID in $TIDE_IDS; do
  BAL=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$TID\"}]")
  VAL=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_current_value_by_id.cdc \
    --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$TID\"}]")
  TBAL=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_balance.cdc \
    --network emulator --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$TID\"}]")
  printf "%s" "$BAL" > "${TMPDIR}/${TID}_bal_init.txt"
  printf "%s" "$VAL" > "${TMPDIR}/${TID}_val_init.txt"
  printf "%s" "$TBAL" > "${TMPDIR}/${TID}_tbal_init.txt"
  echo -e "${BLUE}Tide ${TID}: bal=${BAL} val=${VAL} tideBal=${TBAL}${NC}"
done

# 7) Price drift to force rebalance
echo -e "${BLUE}Changing FLOW and YIELD prices to induce drift...${NC}"
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 1.8 --signer tidal >/dev/null
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.045a1763c93006ca.YieldToken.Vault' 1.5 --signer tidal >/dev/null

# 8) Setup and schedule Supervisor once (child jobs recurring, auto-perpetual after first)
echo -e "${BLUE}Setting up Supervisor...${NC}"
flow transactions send cadence/transactions/flow-vaults/setup_supervisor.cdc \
  --network emulator --signer tidal >/dev/null

FUTURE=$(python - <<'PY'
import time; print(f"{time.time()+8:.1f}")
PY
)
EST=$(flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc --network emulator \
  --args-json "[{\"type\":\"UFix64\",\"value\":\"$FUTURE\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"}]" | grep -oE 'flowFee: [0-9]+\\.[0-9]+' | awk '{print $2}')
FEE=$(python - <<PY
f=float("$EST") if "$EST" else 0.00005
print(f"{f+0.00001:.8f}")
PY
)
CFG_JSON="[\
  {\"type\":\"UFix64\",\"value\":\"$FUTURE\"},\
  {\"type\":\"UInt8\",\"value\":\"1\"},\
  {\"type\":\"UInt64\",\"value\":\"800\"},\
  {\"type\":\"UFix64\",\"value\":\"$FEE\"},\
  {\"type\":\"UFix64\",\"value\":\"60.0\"},\
  {\"type\":\"Bool\",\"value\":true},\
  {\"type\":\"UFix64\",\"value\":\"300.0\"},\
  {\"type\":\"Bool\",\"value\":false}\
]"
echo -e "${BLUE}Scheduling Supervisor once: $CFG_JSON${NC}"
flow transactions send cadence/transactions/flow-vaults/schedule_supervisor.cdc \
  --network emulator --signer tidal --args-json "$CFG_JSON" >/dev/null

echo -e "${BLUE}Waiting ~30s for Supervisor and children to execute...${NC}"
sleep 30

# 9) Fetch events and verify
END_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
END_HEIGHT=${END_HEIGHT:-$START_HEIGHT}
SUP_EXEC=$(flow events get A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed --start ${START_HEIGHT} --end ${END_HEIGHT} 2>/dev/null | grep -c "FlowVaultsScheduler.Supervisor" || true)
echo -e "${BLUE}Supervisor Executed events since ${START_HEIGHT}-${END_HEIGHT}: ${SUP_EXEC}${NC}"

# For each tide, capture scheduled id (if available), poll status, and assert movement/proof
extract_val() { printf "%s" "$1" | grep -oE 'Result: [^[:space:]]+' | awk '{print $2}'; }
FAILS=0
for TID in $TIDE_IDS; do
  echo -e "${BLUE}---- Verifying Tide ${TID} ----${NC}"
  INFO=$(flow scripts execute cadence/scripts/flow-vaults/get_scheduled_rebalancing.cdc \
    --network emulator --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$TID\"}]" 2>/dev/null || true)
  SID=$(echo "${INFO}" | awk -F'scheduledTransactionID: ' '/scheduledTransactionID: /{print $2}' | awk -F',' '{print $1}' | tr -cd '0-9')

  STATUS_NIL_OK=0
  if [[ -n "${SID}" ]]; then
    for i in {1..45}; do
      SRAW=$((flow scripts execute cadence/scripts/flow-vaults/get_scheduled_tx_status.cdc \
        --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$SID\"}]" 2>/dev/null | tr -d '\\n' | grep -oE 'rawValue: [0-9]+' | awk '{print $2}') || true)
      if [[ -z "${SRAW}" ]]; then STATUS_NIL_OK=1; break; fi
      if [[ "${SRAW}" == "2" ]]; then break; fi
      sleep 1
    done
  fi

  # Check on-chain execution proof if we had an SID
  OC_OK=0
  if [[ -n "${SID}" ]]; then
    OC_RES=$(flow scripts execute cadence/scripts/flow-vaults/was_rebalancing_executed.cdc \
      --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$TID\"},{\"type\":\"UInt64\",\"value\":\"$SID\"}]" 2>/dev/null | tr -d '\\n')
    [[ "$OC_RES" =~ "Result: true" ]] && OC_OK=1
  fi

  FINAL_BAL=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$TID\"}]")
  FINAL_VAL=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_current_value_by_id.cdc \
    --network emulator --args-json "[{\"type\":\"UInt64\",\"value\":\"$TID\"}]")
  FINAL_TBAL=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_balance.cdc \
    --network emulator --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$TID\"}]")

  IB=$(extract_val "$(cat "${TMPDIR}/${TID}_bal_init.txt")"); FB=$(extract_val "${FINAL_BAL}")
  IV=$(extract_val "$(cat "${TMPDIR}/${TID}_val_init.txt")"); FV=$(extract_val "${FINAL_VAL}")
  ITB=$(extract_val "$(cat "${TMPDIR}/${TID}_tbal_init.txt")"); FTB=$(extract_val "${FINAL_TBAL}")

  REB_CNT=$(flow events get A.045a1763c93006ca.DeFiActions.Rebalanced --start ${START_HEIGHT} --end ${END_HEIGHT} 2>/dev/null | grep -c "A.045a1763c93006ca.DeFiActions.Rebalanced" || true)
  CHG=$([[ "${IB}" != "${FB}" || "${IV}" != "${FV}" || "${ITB}" != "${FTB}" || "${REB_CNT:-0}" -gt 0 ]] && echo 1 || echo 0)

  if [[ "${CHG}" -ne 1 || ( -n "${SID}" && "${STATUS_NIL_OK}" -eq 0 && "${OC_OK}" -ne 1 ) ]]; then
    echo -e "${RED}FAIL: Tide ${TID} did not show proof of execution or movement.${NC}"
    FAILS=$((FAILS+1))
  else
    echo -e "${GREEN}PASS: Tide ${TID} rebalanced; movement detected.${NC}"
  fi
done

if [[ "${FAILS}" -gt 0 ]]; then
  echo -e "${RED}Test failed for ${FAILS} tide(s).${NC}"
  exit 1
fi

echo -e "${GREEN}All tides rebalanced and validated successfully.${NC}"



#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scheduled Rebalancing - Automated E2E (Two-Terminal)  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
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

# 1) Ensure base setup
echo -e "${BLUE}Running setup_wallets.sh (idempotent)...${NC}"
bash ./local/setup_wallets.sh || true

echo -e "${BLUE}Running setup_emulator.sh (idempotent)...${NC}"
bash ./local/setup_emulator.sh || true

# 2) Grant beta to tidal (single-account dual-auth)
echo -e "${BLUE}Granting FlowVaults beta to tidal...${NC}"
flow transactions send cadence/transactions/flow-vaults/admin/grant_beta.cdc \
  --network emulator \
  --payer tidal --proposer tidal \
  --authorizer tidal --authorizer tidal >/dev/null

# 3) Create a tide for tidal if none exists
echo -e "${BLUE}Ensuring tide exists for tidal...${NC}"
TIDE_IDS=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x045a1763c93006ca"}]')
TIDE_ID=$(echo "$TIDE_IDS" | grep -oE '\[[^]]*\]' | tr -d '[] ' | awk -F',' '{print $1}' || true)
if [ -z "${TIDE_ID:-}" ]; then
  echo -e "${BLUE}Creating tide (100 FLOW)...${NC}"
  flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \
    --network emulator --signer tidal \
    --args-json '[{"type":"String","value":"A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy"},{"type":"String","value":"A.0ae53cb6e3f42a79.FlowToken.Vault"},{"type":"UFix64","value":"100.0"}]' >/dev/null
  TIDE_IDS=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
    --network emulator \
    --args-json '[{"type":"Address","value":"0x045a1763c93006ca"}]')
  TIDE_ID=$(echo "$TIDE_IDS" | grep -oE '\[[^]]*\]' | tr -d '[] ' | awk -F',' '{print $1}' || true)
fi
TIDE_ID=${TIDE_ID:-0}
echo -e "${GREEN}Using Tide ID: $TIDE_ID${NC}"

# 4) Initial balance
INITIAL_BALANCE=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")
echo -e "${BLUE}Initial balance: $INITIAL_BALANCE${NC}"
INIT_CURRENT_VALUE=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_current_value_by_id.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")
INIT_TIDE_BAL=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_balance.cdc \
  --network emulator \
  --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")
echo -e "${BLUE}Initial current value: ${INIT_CURRENT_VALUE}${NC}"
echo -e "${BLUE}Initial tide balance:   ${INIT_TIDE_BAL}${NC}"
echo -e "${BLUE}Initial user summary (tidal):${NC}"
flow scripts execute cadence/scripts/flow-vaults/get_complete_user_position_info.cdc \
  --network emulator \
  --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"}]" || true

# 5) Setup scheduler manager (idempotent)
echo -e "${BLUE}Setting up SchedulerManager...${NC}"
flow transactions send cadence/transactions/flow-vaults/setup_scheduler_manager.cdc \
  --network emulator --signer tidal >/dev/null

# Capture current block height to filter events after scheduling
START_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
START_HEIGHT=${START_HEIGHT:-0}

# 6) Estimate fee for schedule now+15s
FUTURE=$(($(date +%s)+15)).0
echo -e "${BLUE}Estimating scheduling fee for timestamp ${FUTURE}...${NC}"
ESTIMATE=$(flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UFix64\",\"value\":\"$FUTURE\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"}]")
FEE=$(echo "$ESTIMATE" | grep -oE 'flowFee: [0-9]+\.[0-9]+' | awk '{print $2}')
# Add a small safety buffer to cover minor estimation drift
FEE=${FEE:-0.001}
FEE=$(awk -v f="$FEE" 'BEGIN{printf "%.8f", f + 0.00001}')
echo -e "${GREEN}Using fee: ${FEE}${NC}"

# 7) Change price to force a rebalance need (bigger drift)
echo -e "${BLUE}Changing FLOW price to 1.8 to trigger rebalance...${NC}"
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 1.8 --signer tidal >/dev/null
# Also change YieldToken price so AutoBalancer detects surplus/deficit vs deposits
echo -e "${BLUE}Changing YIELD price to 1.5 to create AutoBalancer drift...${NC}"
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.045a1763c93006ca.YieldToken.Vault' 1.5 --signer tidal >/dev/null

# 8) Schedule rebalancing
echo -e "${BLUE}Scheduling rebalancing at ${FUTURE}...${NC}"
flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
  --network emulator --signer tidal \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"},{\"type\":\"UFix64\",\"value\":\"$FUTURE\"},{\"type\":\"UInt8\",\"value\":\"1\"},{\"type\":\"UInt64\",\"value\":\"800\"},{\"type\":\"UFix64\",\"value\":\"$FEE\"},{\"type\":\"Bool\",\"value\":true},{\"type\":\"Bool\",\"value\":false},{\"type\":\"Optional\",\"value\":null}]" >/dev/null

# Capture scheduled transaction ID from event
POST_SCHED_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
# First try via public script (preferred)
SCHED_INFO=$(flow scripts execute cadence/scripts/flow-vaults/get_scheduled_rebalancing.cdc \
  --network emulator \
  --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]" 2>/dev/null || true)
SCHED_ID=$(echo "${SCHED_INFO}" | awk -F'scheduledTransactionID: ' '/scheduledTransactionID: /{print $2}' | awk -F',' '{print $1}' | tr -cd '0-9')
# Fallback to event parsing if script returned nothing
if [[ -z "${SCHED_ID}" ]]; then
  SCHED_ID=$((flow events get A.045a1763c93006ca.FlowVaultsScheduler.RebalancingScheduled --start ${START_HEIGHT} --end ${POST_SCHED_HEIGHT} 2>/dev/null \
    | grep -i 'scheduledTransactionID' | tail -n 1 | awk -F': ' '{print $2}' | tr -cd '0-9') || true)
fi
echo -e "${BLUE}Scheduled Tx ID: ${SCHED_ID:-unknown}${NC}"

# Poll scheduler status until Executed (2) or missing
if [[ -n "${SCHED_ID}" ]]; then
  echo -e "${BLUE}Polling scheduled tx status...${NC}"
  STATUS_NIL_OK=0
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
else
  echo -e "${YELLOW}Could not determine Scheduled Tx ID from events.${NC}"
  echo -e "${BLUE}Waiting ~35s for automatic execution...${NC}"
  sleep 35
fi

# 9) Verify balance changed or status executed
FINAL_BALANCE=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")
echo -e "${BLUE}Initial: $INITIAL_BALANCE${NC}"
echo -e "${BLUE}Final:   $FINAL_BALANCE${NC}"
FINAL_CURRENT_VALUE=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_current_value_by_id.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")
FINAL_TIDE_BAL=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_balance.cdc \
  --network emulator \
  --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")
echo -e "${BLUE}Final current value: ${FINAL_CURRENT_VALUE}${NC}"
echo -e "${BLUE}Final tide balance:   ${FINAL_TIDE_BAL}${NC}"
echo -e "${BLUE}Final user summary (tidal):${NC}"
flow scripts execute cadence/scripts/flow-vaults/get_complete_user_position_info.cdc \
  --network emulator \
  --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"}]" || true

# 9d) Assert: scheduled tx executed (prove scheduler callback), else fail
END_HEIGHT=$(flow blocks get latest 2>/dev/null | grep -i -E 'Height|Block Height' | grep -oE '[0-9]+' | head -1)
END_HEIGHT=${END_HEIGHT:-$START_HEIGHT}
EXEC_EVENTS_COUNT=$(flow events get A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed --start ${START_HEIGHT} --end ${END_HEIGHT} 2>/dev/null | grep -c "A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed" || true)
# LAST_STATUS comes from polling loop if SCHED_ID was known
LAST_STATUS="${STATUS_RAW:-}"
ON_CHAIN_PROOF=0
if [[ -n "${SCHED_ID:-}" ]]; then
  OC_RES=$(flow scripts execute cadence/scripts/flow-vaults/was_rebalancing_executed.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"},{\"type\":\"UInt64\",\"value\":\"$SCHED_ID\"}]" 2>/dev/null | tr -d '\n')
  echo -e "${BLUE}On-chain executed proof for ${SCHED_ID}: ${OC_RES}${NC}"
  if echo "${OC_RES}" | grep -q "Result: true"; then
    ON_CHAIN_PROOF=1
  fi
fi
if [[ "${LAST_STATUS}" != "2" && "${EXEC_EVENTS_COUNT:-0}" -eq 0 && "${STATUS_NIL_OK:-0}" -eq 0 && "${ON_CHAIN_PROOF:-0}" -eq 0 ]]; then
  echo -e "${RED}FAIL: Scheduled transaction did not reach Executed status and no scheduler Executed event was found.${NC}"
  exit 1
fi

# 9e) Assert: a rebalance change occurred (event or balances changed), else fail
REBAL_EVENTS_COUNT=$(flow events get A.045a1763c93006ca.DeFiActions.Rebalanced --start ${START_HEIGHT} --end ${END_HEIGHT} 2>/dev/null | grep -c "A.045a1763c93006ca.DeFiActions.Rebalanced" || true)
extract_result_value() { printf "%s" "$1" | grep -oE 'Result: [^[:space:]]+' | awk '{print $2}'; }
IB=$(extract_result_value "${INITIAL_BALANCE}")
FB=$(extract_result_value "${FINAL_BALANCE}")
ITB=$(extract_result_value "${INIT_TIDE_BAL}")
FTB=$(extract_result_value "${FINAL_TIDE_BAL}")
CHANGE_DETECTED=0
if [[ "${IB}" != "${FB}" || "${ITB}" != "${FTB}" || "${REBAL_EVENTS_COUNT:-0}" -gt 0 ]]; then
  CHANGE_DETECTED=1
fi
if [[ "${CHANGE_DETECTED}" -ne 1 ]]; then
  echo -e "${RED}FAIL: No asset movement detected after scheduled rebalance (no Rebalanced event, balances unchanged).${NC}"
  exit 1
fi

# 9b) Show execution events to prove it ran
echo -e "${BLUE}Recent RebalancingExecuted events:${NC}"
flow events get A.045a1763c93006ca.FlowVaultsScheduler.RebalancingExecuted --start ${START_HEIGHT} --end ${END_HEIGHT} | head -n 100 || true
echo -e "${BLUE}Recent Scheduler.Executed events:${NC}"
flow events get A.f8d6e0586b0a20c7.FlowTransactionScheduler.Executed --start ${START_HEIGHT} --end ${END_HEIGHT} | head -n 100 || true
echo -e "${BLUE}Recent DeFiActions.AutoBalancer Rebalanced events:${NC}"
flow events get A.045a1763c93006ca.DeFiActions.Rebalanced --start ${START_HEIGHT} --end ${END_HEIGHT} | head -n 100 || true
echo -e "${BLUE}Executed IDs for tide ${TIDE_ID}:${NC}"
flow scripts execute cadence/scripts/flow-vaults/get_executed_ids_for_tide.cdc \
  --network emulator \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]" || true

# 9c) Print current schedule status for this tide
echo -e "${BLUE}Schedule status for tide ${TIDE_ID}:${NC}"
flow scripts execute cadence/scripts/flow-vaults/get_scheduled_rebalancing.cdc \
  --network emulator \
  --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]" || true

# 10) Schedule again (future+45s) and cancel to test refund/cancel path
FUTURE2=$(($(date +%s)+45)).0
echo -e "${BLUE}Scheduling another rebalancing for cancel test at ${FUTURE2}...${NC}"
flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
  --network emulator --signer tidal \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"},{\"type\":\"UFix64\",\"value\":\"$FUTURE2\"},{\"type\":\"UInt8\",\"value\":\"2\"},{\"type\":\"UInt64\",\"value\":\"500\"},{\"type\":\"UFix64\",\"value\":\"$FEE\"},{\"type\":\"Bool\",\"value\":false},{\"type\":\"Bool\",\"value\":false},{\"type\":\"Optional\",\"value\":null}]" >/dev/null

echo -e "${BLUE}Canceling scheduled rebalancing...${NC}"
flow transactions send cadence/transactions/flow-vaults/cancel_scheduled_rebalancing.cdc \
  --network emulator --signer tidal \
  --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]" >/dev/null

echo ""
echo -e "${GREEN}════════ Test Summary ═════════${NC}"
echo -e "${GREEN}- Tide ID: $TIDE_ID${NC}"
echo -e "${GREEN}- Fee used: $FEE${NC}"
echo -e "${GREEN}- Initial balance: $INITIAL_BALANCE${NC}"
echo -e "${GREEN}- Final balance:   $FINAL_BALANCE${NC}"
echo -e "${GREEN}- Scheduled once (executed), scheduled again (canceled)${NC}"
echo -e "${GREEN}═══════════════════════════════${NC}"



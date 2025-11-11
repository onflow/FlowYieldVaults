#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

assert_true() {
  local cond="$1"
  local msg="$2"
  if eval "$cond"; then
    echo -e "${GREEN}PASS${NC} - $msg"
    pass_count=$((pass_count+1))
  else
    echo -e "${RED}FAIL${NC} - $msg"
    fail_count=$((fail_count+1))
  fi
}

num_eq() {
  awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a==b) }'
}

num_ne() {
  awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a!=b) }'
}

num_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a>b) }'
}

extract_result_value() {
  grep -oE 'Result: .*' | sed 's/Result: //'
}

echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scheduled Rebalancing Scenarios (Two-Terminal)     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}Waiting for emulator (3569) to be ready...${NC}"
for i in {1..30}; do
  if nc -z 127.0.0.1 3569; then
    echo -e "${GREEN}Emulator ready.${NC}"
    break
  fi
  sleep 1
done
nc -z 127.0.0.1 3569 || { echo -e "${RED}Emulator not detected on port 3569${NC}"; exit 1; }

echo -e "${BLUE}Ensuring accounts and contracts are set up...${NC}"
bash ./local/setup_wallets.sh >/dev/null 2>&1 || true
bash ./local/setup_emulator.sh >/dev/null 2>&1 || true

echo -e "${BLUE}Granting Beta to tidal (idempotent)...${NC}"
flow transactions send cadence/transactions/flow-vaults/admin/grant_beta.cdc \
  --network emulator \
  --payer tidal --proposer tidal \
  --authorizer tidal --authorizer tidal >/dev/null 2>&1 || true

echo -e "${BLUE}Creating a fresh Tide for isolated scenarios...${NC}"
flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \
  --network emulator --signer tidal \
  --args-json '[{"type":"String","value":"A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy"},{"type":"String","value":"A.0ae53cb6e3f42a79.FlowToken.Vault"},{"type":"UFix64","value":"100.0"}]' >/dev/null
TIDE_IDS=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x045a1763c93006ca"}]')
TIDE_ID=$(echo "$TIDE_IDS" | grep -oE '\[.*\]' | tr -d '[] ' | awk -F',' '{print $NF}')
echo -e "${GREEN}Using new Tide ID: $TIDE_ID${NC}"

echo -e "${BLUE}Resetting SchedulerManager to clear any leftovers...${NC}"
flow transactions send cadence/transactions/flow-vaults/reset_scheduler_manager.cdc \
  --network emulator --signer tidal >/dev/null 2>&1 || true
flow transactions send cadence/transactions/flow-vaults/setup_scheduler_manager.cdc \
  --network emulator --signer tidal >/dev/null 2>&1 || true

get_balance() {
  flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]" | extract_result_value
}

get_status() {
  flow scripts execute cadence/scripts/flow-vaults/get_scheduled_rebalancing.cdc \
    --network emulator \
    --args-json "[{\"type\":\"Address\",\"value\":\"0x045a1763c93006ca\"},{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]" | extract_result_value
}

get_status_value() {
  get_status | tr -d '\n' | grep -oE 'rawValue: [0-9]+' | awk '{print $2}' | tr -cd '0-9'
}

schedule_at() {
  local ts="$1" pr="$2" eff="$3" fee="$4" force="$5" recurring="$6" interval_opt="$7"
  flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
    --network emulator --signer tidal \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"},{\"type\":\"UFix64\",\"value\":\"$ts\"},{\"type\":\"UInt8\",\"value\":\"$pr\"},{\"type\":\"UInt64\",\"value\":\"$eff\"},{\"type\":\"UFix64\",\"value\":\"$fee\"},{\"type\":\"Bool\",\"value\":$force},{\"type\":\"Bool\",\"value\":$recurring},{\"type\":\"Optional\",\"value\":$interval_opt}]" >/dev/null
}

cancel_schedule() {
  flow transactions send cadence/transactions/flow-vaults/cancel_scheduled_rebalancing.cdc \
    --network emulator --signer tidal \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]" >/dev/null
}

echo -e "${BLUE}Resetting prices to 1.0...${NC}"
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 1.0 --signer tidal >/dev/null
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.045a1763c93006ca.YieldToken.Vault' 1.0 --signer tidal >/dev/null

BASE_BAL=$(get_balance)
echo -e "${BLUE}Base AutoBalancer balance: $BASE_BAL${NC}"

# Scenario 1: No drift, force=false => expect no change (still executed)
FUTURE=$(($(date +%s)+10)).0
FEE=0.001
schedule_at "$FUTURE" 1 800 "$FEE" false false "null"
sleep 15
S1_BAL=$(get_balance)
assert_true "num_eq \"$S1_BAL\" \"$BASE_BAL\"" "Scenario 1: no drift, force=false keeps balance"
S1_STATUS=$(get_status_value || true)
assert_true "num_eq \"${S1_STATUS:-0}\" \"2\"" "Scenario 1: scheduled tx executed"

# Scenario 2: No drift, force=true => executed (balance may or may not change)
FUTURE=$(($(date +%s)+10)).0
FEE=0.001
schedule_at "$FUTURE" 1 800 "$FEE" true false "null"
sleep 15
S2_STATUS=$(get_status_value || true)
assert_true "num_eq \"${S2_STATUS:-0}\" \"2\"" "Scenario 2: scheduled tx executed (force=true)"

# Scenario 3: Drift (FLOW price 1.5), force=false => executed
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  'A.0ae53cb6e3f42a79.FlowToken.Vault' 1.5 --signer tidal >/dev/null
FUTURE=$(($(date +%s)+10)).0
FEE=0.001
schedule_at "$FUTURE" 0 800 "$FEE" false false "null"
sleep 15
S3_STATUS=$(get_status_value || true)
assert_true "num_eq \"${S3_STATUS:-0}\" \"2\"" "Scenario 3: scheduled tx executed with drift"

# Scenario 4: Recurring every 5s (with drift), expect present at least once
FUTURE=$(($(date +%s)+10)).0
FEE=0.001
schedule_at "$FUTURE" 1 500 "$FEE" false true '{"type":"UFix64","value":"5.0"}'
sleep 20
R_STATUS=$(get_status || true)
assert_true "[[ -n \"${R_STATUS}\" ]]" "Scenario 4: recurring schedule present"
cancel_schedule || true

echo ""
echo -e "${GREEN}Passed: $pass_count${NC}  ${RED}Failed: $fail_count${NC}"
exit $fail_count



# Complete Testnet Scheduled Rebalancing Test - Full Setup

## You're Right! Let's Use the Emulator Test Approach

The emulator tests already show us how to set up MockSwapper for FULL rebalancing. We just need to do the same thing on testnet!

---

## Setup Steps (Replicating Emulator Tests)

### Step 1: Set Up MockSwapper Liquidity

Just like in the emulator tests, we need to configure MockSwapper liquidity connectors:

```bash
# Set up liquidity for FlowToken
flow transactions send cadence/transactions/mocks/swapper/set_liquidity_connector.cdc \
    --network=testnet --signer=keshav-scheduled-testnet \
    --args-json '[{"type":"StoragePath","value":{"domain":"storage","identifier":"flowTokenVault"}}]'
```

### Step 2: Fund the Account with Tokens

```bash
# You already have FLOW, so you're good!
# Balance: ~100,000 FLOW ✅
```

### Step 3: Deploy TestStrategyWithAutoBalancer

Since you already deployed it, verify:
```bash
flow accounts get 0x425216a69bec3d42 --network=testnet | grep TestStrategy
```

### Step 4: Add Strategy Composer (Already Done!)

You mentioned both steps are done, so we're good! ✅

---

## Now Test Scheduled Rebalancing

### Step 5: Grant Beta Access

```bash
flow transactions send cadence/transactions/flow-vaults/admin/grant_beta.cdc \
    --network=testnet --signer=keshav-scheduled-testnet \
    --args-json '[
      {"type":"Address","value":"0x425216a69bec3d42"},
      {"type":"Address","value":"0x425216a69bec3d42"}
    ]'
```

### Step 6: Create a Tide

```bash
flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \
    --network=testnet --signer=keshav-scheduled-testnet \
    --args-json '[
      {"type":"String","value":"A.425216a69bec3d42.TestStrategyWithAutoBalancer.Strategy"},
      {"type":"String","value":"A.7e60df042a9c0868.FlowToken.Vault"},
      {"type":"UFix64","value":"100.0"}
    ]'
```

### Step 7: Get Tide ID

```bash
flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
    --network=testnet \
    --args-json '[{"type":"Address","value":"0x425216a69bec3d42"}]'
```

Note the tide ID (probably 0).

### Step 8: Check Initial AutoBalancer Balance

```bash
TIDE_ID=0

flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network=testnet \
    --args-json '[{"type":"UInt64","value":"'$TIDE_ID'"}]'
```

### Step 9: Set MockOracle Price (Create Rebalancing Need)

```bash
# Change FLOW price to 1.5 (creates rebalancing opportunity)
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
    --network=testnet --signer=keshav-scheduled-testnet \
    --args-json '[
      {"type":"String","value":"A.7e60df042a9c0868.FlowToken.Vault"},
      {"type":"UFix64","value":"1.5"}
    ]'
```

### Step 10: Setup SchedulerManager

```bash
flow transactions send cadence/transactions/flow-vaults/setup_scheduler_manager.cdc \
    --network=testnet --signer=keshav-scheduled-testnet
```

### Step 11: Schedule Rebalancing for 5 Minutes from Now

```bash
TIDE_ID=0
FUTURE=$(($(date +%s) + 300))
echo "Scheduling for timestamp: $FUTURE (5 minutes from now)"

flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
    --network=testnet --signer=keshav-scheduled-testnet \
    --args-json '[
      {"type":"UInt64","value":"'$TIDE_ID'"},
      {"type":"UFix64","value":"'$FUTURE'.0"},
      {"type":"UInt8","value":"1"},
      {"type":"UInt64","value":"500"},
      {"type":"UFix64","value":"0.002"},
      {"type":"Bool","value":true},
      {"type":"Bool","value":false},
      {"type":"Optional","value":null}
    ]'
```

### Step 12: ⏰ WAIT 6 MINUTES

This is the crucial moment! The FVM will automatically:
1. Detect the scheduled time has arrived
2. Call AutoBalancer.executeTransaction()
3. Which calls AutoBalancer.rebalance()
4. Which will rebalance based on the price change!

### Step 13: Verify Automatic Execution

```bash
# Check for RebalancingExecuted event
flow events get A.425216a69bec3d42.FlowVaultsScheduler.RebalancingExecuted \
    --network=testnet \
    --start=289567000 --end=999999999

# Check if rebalancing happened
flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network=testnet \
    --args-json '[{"type":"UInt64","value":"'$TIDE_ID'"}]'

# Check FlowTransactionScheduler.Executed event
flow events get A.8c5303eaa26202d6.FlowTransactionScheduler.Executed \
    --network=testnet \
    --start=289567000 --end=999999999
```

---

## Success Criteria

✅ **RebalancingExecuted event** - Proves scheduler called our code  
✅ **FlowTransactionScheduler.Executed** - Proves FVM executed it  
✅ **AutoBalancer balance changed** - Proves rebalancing happened  
✅ **All automatic** - No manual trigger  

**This proves the COMPLETE scheduled rebalancing flow works!**

---

## Start Here

1. Run Step 1 (set up MockSwapper liquidity)
2. Then Steps 5-11
3. Wait 6 minutes
4. Check Step 13

This will give you the complete end-to-end proof! 🚀


# Scheduled Rebalancing Guide

This guide explains how scheduled rebalancing works for FlowVaults Tides.

## Overview

FlowVaults integrates with Flow's native transaction scheduler ([FLIP 330](https://github.com/onflow/flips/pull/330)) to enable automatic rebalancing of Tides without manual intervention.

### Key Features

- **Automatic Setup**: Tides are automatically scheduled for rebalancing upon creation
- **Self-Scheduling**: AutoBalancers chain their own subsequent executions
- **Recovery System**: Supervisor handles failed schedules via bounded pending queue
- **Cancellation**: Cancel scheduled transactions and receive partial refunds

---

## Architecture

### How It Works

```
Tide Creation (Atomic)
         |
         v
FlowVaultsAutoBalancers._initNewAutoBalancer()
         |
         v
FlowVaultsScheduler.registerTide()
    |-- Issues capability to AutoBalancer
    |-- Registers in FlowVaultsSchedulerRegistry
    +-- Schedules first execution
         |
         v
FlowTransactionScheduler executes at scheduled time
         |
         v
AutoBalancer.executeTransaction()
    |-- Calls rebalance()
    +-- Self-schedules next execution (if recurring)
```

### Components

1. **FlowVaultsScheduler**: Manages registration and scheduling
2. **FlowVaultsSchedulerRegistry**: Stores registry of tides and pending queue
3. **AutoBalancer**: Implements `TransactionHandler`, executes rebalancing
4. **Supervisor**: Recovery handler for failed schedules (paginated)

### No Wrapper Needed

AutoBalancers implement `FlowTransactionScheduler.TransactionHandler` directly. The capability is issued to the AutoBalancer's storage path - no intermediate wrapper.

---

## Automatic Scheduling

### On Tide Creation

When you create a Tide, it's automatically:
1. Registered with the scheduler
2. Scheduled for its first rebalancing execution

**No manual setup required!**

```bash
# Simply create a tide - scheduling happens automatically
flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \
  --arg String:"TracerStrategy" \
  --arg String:"FlowToken" \
  --arg UFix64:100.0
```

### Self-Scheduling

After the first execution, AutoBalancers with `recurringConfig` automatically schedule their next execution. This chains indefinitely until:
- The tide is closed
- The schedule is manually canceled
- The account runs out of FLOW for fees

---

## Manual Scheduling (Optional)

If you need to manually schedule (e.g., after canceling the auto-schedule):

### Step 1: Cancel Existing Schedule

```bash
flow transactions send cadence/transactions/flow-vaults/cancel_scheduled_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID
```

### Step 2: Estimate Costs

```bash
flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc \
  --arg UFix64:1699920000.0 \    # timestamp
  --arg UInt8:1 \                 # priority (0=High, 1=Medium, 2=Low)
  --arg UInt64:500                # execution effort
```

### Step 3: Schedule

```bash
flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID \
  --arg UFix64:1699920000.0 \     # timestamp
  --arg UInt8:1 \                 # priority
  --arg UInt64:500 \              # execution effort
  --arg UFix64:0.0015 \           # fee amount
  --arg Bool:false \              # force
  --arg Bool:true \               # isRecurring
  --arg UFix64:86400.0            # recurringInterval (seconds)
```

---

## Monitoring

### View All Scheduled Rebalancing

```bash
flow scripts execute cadence/scripts/flow-vaults/get_all_scheduled_rebalancing.cdc \
  --arg Address:FLOWVAULTS_ADDRESS
```

### View Specific Tide Schedule

```bash
flow scripts execute cadence/scripts/flow-vaults/get_scheduled_rebalancing.cdc \
  --arg Address:FLOWVAULTS_ADDRESS \
  --arg UInt64:YOUR_TIDE_ID
```

### Check Registered Tides

```bash
flow scripts execute cadence/scripts/flow-vaults/get_registered_tide_ids.cdc
```

### Check Pending Queue

```bash
flow scripts execute cadence/scripts/flow-vaults/get_pending_count.cdc
```

---

## Priority Levels

| Priority | Execution Guarantee | Fee Multiplier | Use Case |
|----------|-------------------|----------------|----------|
| **High** (0) | First-block execution | 10x | Time-critical |
| **Medium** (1) | Best-effort | 5x | Standard |
| **Low** (2) | Opportunistic | 2x | Cost-sensitive |

---

## Recovery (Supervisor)

### What It Does

The Supervisor handles tides that failed to self-schedule:
- Processes bounded `pendingQueue` (MAX 50 tides per run)
- Schedules failed tides
- Self-reschedules if more work remains

### When It's Needed

1. AutoBalancer fails to schedule due to insufficient FLOW
2. Network issues during scheduling
3. Capability becomes invalid

### Manual Recovery

If monitoring detects a failed schedule, enqueue for recovery:

```bash
flow transactions send cadence/transactions/flow-vaults/enqueue_pending_tide.cdc \
  --arg UInt64:TIDE_ID
```

The next Supervisor run will re-seed the tide.

---

## Events

### FlowVaultsScheduler Events

```cadence
event RebalancingScheduled(
    tideID: UInt64,
    scheduledTransactionID: UInt64,
    timestamp: UFix64,
    priority: UInt8,
    isRecurring: Bool,
    recurringInterval: UFix64?,
    force: Bool
)

event RebalancingCanceled(
    tideID: UInt64,
    scheduledTransactionID: UInt64,
    feesReturned: UFix64
)

event SupervisorSeededTide(
    tideID: UInt64,
    scheduledTransactionID: UInt64,
    timestamp: UFix64
)
```

### FlowVaultsSchedulerRegistry Events

```cadence
event TideRegistered(tideID: UInt64, handlerCapValid: Bool)
event TideUnregistered(tideID: UInt64, wasInPendingQueue: Bool)
event TideEnqueuedPending(tideID: UInt64, pendingQueueSize: Int)
event TideDequeuedPending(tideID: UInt64, pendingQueueSize: Int)
```

---

## Cancellation

### Cancel a Schedule

```bash
flow transactions send cadence/transactions/flow-vaults/cancel_scheduled_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID
```

**Note**: Partial refunds are subject to the scheduler's refund policy.

### What Happens on Tide Close

When a tide is closed:
1. `_cleanupAutoBalancer()` is called
2. `unregisterTide()` cancels pending schedules
3. Fees are refunded to the FlowVaults account
4. Tide is removed from registry

---

## Troubleshooting

### "Insufficient FLOW balance for scheduling"

The FlowVaults account needs FLOW to pay for scheduling fees. Fund the account:

```bash
flow transactions send --code "
import FlowToken from 0xFlowToken
import FungibleToken from 0xFungibleToken

transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        // Transfer FLOW to FlowVaults account
    }
}
" --arg UFix64:10.0
```

### "Rebalancing already scheduled"

Cancel the existing schedule first:

```bash
flow transactions send cadence/transactions/flow-vaults/cancel_scheduled_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID
```

### Schedule Not Executing

Check:
1. Timestamp is in the future
2. FlowVaults account has sufficient FLOW
3. Priority level (Low may be delayed)
4. Handler capability is valid

---

## Best Practices

1. **Trust Automatic Scheduling**: Let the system handle scheduling automatically
2. **Monitor Events**: Watch for `TideEnqueuedPending` events indicating failed schedules
3. **Maintain FLOW Balance**: Ensure FlowVaults account has sufficient FLOW for fees
4. **Use Appropriate Priority**: Medium is usually sufficient

---

## FAQ

**Q: Do I need to manually schedule rebalancing?**  
A: No, tides are automatically scheduled upon creation.

**Q: What happens if scheduling fails?**  
A: The tide creation reverts entirely (atomic operation).

**Q: How does recurring work?**  
A: AutoBalancers self-schedule their next execution after each run.

**Q: What if the FlowVaults account runs out of FLOW?**  
A: AutoBalancers will fail to self-schedule. Monitor for `FailedRecurringSchedule` events and fund the account.

**Q: Can I have multiple schedules for one tide?**  
A: No, one schedule per tide. Cancel to reschedule.

---

**Last Updated**: November 26, 2025  
**Version**: 2.0.0

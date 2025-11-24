# Scheduled Rebalancing Guide

This guide explains how to use the scheduled rebalancing feature for FlowVaults Tides, which enables autonomous, time-based rebalancing of your positions.

## Overview

The FlowVaults Scheduler integrates with Flow's native transaction scheduler ([FLIP 330](https://github.com/onflow/flips/pull/330)) to enable automatic rebalancing of Tides at predefined times without requiring manual intervention.

### Key Features

- **Autonomous Execution**: Rebalancing happens automatically at scheduled times
- **Flexible Scheduling**: One-time or recurring schedules (hourly, daily, weekly, etc.)
- **Priority Levels**: Choose execution guarantees (High, Medium, or Low priority)
- **Cost Estimation**: Know exactly how much FLOW is needed before scheduling
- **Cancellation**: Cancel scheduled transactions and receive partial refunds

## Testing Status

⚠️ **Important:** This implementation has been tested for infrastructure but not yet tested end-to-end with automatic rebalancing execution on testnet.

**What's Verified:**
- ✅ Schedule creation and management
- ✅ Cost estimation
- ✅ Cancellation
- ✅ Counter test proves automatic execution mechanism works on testnet

**What Needs Testing:**
- ⏳ Full rebalancing with actual tide on testnet
- ⏳ Automatic execution with price changes
- ⏳ Verification of rebalancing at scheduled time

Use with understanding that while the infrastructure is solid and the pattern is proven (via counter test), the full rebalancing flow hasn't been tested end-to-end yet.

---

## Architecture

### Components

1. **FlowVaultsScheduler Contract**: Manages scheduled rebalancing transactions
2. **RebalancingHandler**: Transaction handler that executes rebalancing
3. **SchedulerManager**: Resource that tracks and manages schedules for an account
4. **FlowTransactionScheduler**: Flow's system contract for autonomous transactions

**Note**: Tides are automatically registered with the Scheduler system upon creation.

### How It Works

```
User schedules rebalancing
         ↓
FlowVaultsScheduler creates RebalancingHandler (automatically on Tide creation)
         ↓
FlowTransactionScheduler schedules execution
         ↓
At scheduled time, FVM executes the handler
         ↓
RebalancingHandler calls AutoBalancer.rebalance()
         ↓
Tide is rebalanced
```

## Getting Started

### Step 1: Setup (First Time Only)

Before scheduling any rebalancing, set up the SchedulerManager:

```bash
flow transactions send cadence/transactions/flow-vaults/setup_scheduler_manager.cdc
```

**Note**: This step is optional if you use `schedule_rebalancing.cdc`, which automatically sets up the manager if needed.

### Step 2: Estimate Costs

Before scheduling, estimate how much FLOW is required:

```bash
flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc \
  --arg UFix64:1699920000.0 \    # timestamp (Unix time)
  --arg UInt8:1 \                 # priority (0=High, 1=Medium, 2=Low)
  --arg UInt64:500                # execution effort
```

**Output Example**:
```json
{
  "flowFee": 0.00123456,
  "timestamp": 1699920000.0,
  "error": null
}
```

### Step 3: Schedule Rebalancing

Schedule a rebalancing transaction:

```bash
flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
  --arg UInt64:1 \                # tideID
  --arg UFix64:1699920000.0 \     # timestamp
  --arg UInt8:1 \                 # priority (1=Medium)
  --arg UInt64:500 \              # execution effort
  --arg UFix64:0.0015 \           # fee amount (from estimate + buffer)
  --arg Bool:false \              # force (false = respect thresholds)
  --arg Bool:true \               # isRecurring (true = repeat)
  --arg UFix64:86400.0            # recurringInterval (24 hours in seconds)
```

## Usage Examples

### Example 1: Daily Rebalancing

Rebalance every day at midnight (respecting thresholds):

```bash
# Calculate tomorrow's midnight timestamp
TOMORROW_MIDNIGHT=$(date -d "tomorrow 00:00:00" +%s)

# Estimate cost
flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc \
  --arg UFix64:${TOMORROW_MIDNIGHT}.0 \
  --arg UInt8:1 \
  --arg UInt64:500

# Schedule
flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID \
  --arg UFix64:${TOMORROW_MIDNIGHT}.0 \
  --arg UInt8:1 \
  --arg UInt64:500 \
  --arg UFix64:0.002 \
  --arg Bool:false \
  --arg Bool:true \
  --arg UFix64:86400.0
```

### Example 2: One-Time Emergency Rebalancing

Force rebalancing once in 1 hour:

```bash
# Calculate timestamp (1 hour from now)
FUTURE_TIME=$(date -d "+1 hour" +%s)

flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID \
  --arg UFix64:${FUTURE_TIME}.0 \
  --arg UInt8:0 \              # High priority for faster execution
  --arg UInt64:800 \
  --arg UFix64:0.005 \
  --arg Bool:true \            # Force = true (ignore thresholds)
  --arg Bool:false \           # One-time only
  --arg UFix64:0.0
```

### Example 3: Hourly Rebalancing (High Frequency)

Rebalance every hour starting in 1 hour:

```bash
FUTURE_TIME=$(date -d "+1 hour" +%s)

flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID \
  --arg UFix64:${FUTURE_TIME}.0 \
  --arg UInt8:1 \
  --arg UInt64:500 \
  --arg UFix64:0.002 \
  --arg Bool:false \
  --arg Bool:true \
  --arg UFix64:3600.0          # 1 hour = 3600 seconds
```

## Monitoring & Management

### View All Scheduled Rebalancing

See all scheduled rebalancing for your account:

```bash
flow scripts execute cadence/scripts/flow-vaults/get_all_scheduled_rebalancing.cdc \
  --arg Address:YOUR_ADDRESS
```

### View Specific Tide Schedule

Check the schedule for a specific Tide:

```bash
flow scripts execute cadence/scripts/flow-vaults/get_scheduled_rebalancing.cdc \
  --arg Address:YOUR_ADDRESS \
  --arg UInt64:YOUR_TIDE_ID
```

### Check Scheduled Tide IDs

List all Tide IDs with active schedules:

```bash
flow scripts execute cadence/scripts/flow-vaults/get_scheduled_tide_ids.cdc \
  --arg Address:YOUR_ADDRESS
```

### Cancel Scheduled Rebalancing

Cancel a schedule and receive a partial refund:

```bash
flow transactions send cadence/transactions/flow-vaults/cancel_scheduled_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID
```

**Note**: Refunds are subject to the scheduler's refund policy (typically 50% of the fee).

## Priority Levels

Choose the appropriate priority based on your needs:

| Priority | Execution Guarantee | Fee Multiplier | Use Case |
|----------|-------------------|----------------|----------|
| **High** (0) | Guaranteed first-block execution at exact timestamp | 10x | Time-critical rebalancing |
| **Medium** (1) | Best-effort near requested time | 5x | Standard scheduled rebalancing |
| **Low** (2) | Opportunistic when capacity allows | 2x | Non-urgent, cost-sensitive |

## Execution Effort

The `executionEffort` parameter determines:
- The computational resources allocated
- The fee charged (higher effort = higher fee)
- Whether the transaction can be scheduled

**Recommended values**:
- Simple rebalancing: `500` - `800`
- Complex strategies: `1000` - `2000`
- Maximum allowed: `9999` (check current config)

**Important**: Unused execution effort is NOT refunded. Choose wisely!

## Cost Considerations

### Fee Calculation

```
Total Fee = (Base Fee × Priority Multiplier) + Storage Fee
```

- **Base Fee**: Calculated from execution effort
- **Priority Multiplier**: 2x (Low), 5x (Medium), 10x (High)
- **Storage Fee**: Minimal cost for storing transaction data

### Budgeting Tips

1. Use the estimate script before scheduling
2. Add a 10-20% buffer to the estimated fee
3. Consider lower priority for recurring transactions
4. Monitor refund policies for cancellations

## Recurring Schedules

### How Recurring Works

When `isRecurring = true`:
1. First execution happens at `timestamp`
2. Subsequent executions happen at `timestamp + (n × recurringInterval)`
3. Continues indefinitely until canceled

### Common Intervals

- **Hourly**: `3600.0` seconds
- **Every 6 hours**: `21600.0` seconds
- **Daily**: `86400.0` seconds
- **Weekly**: `604800.0` seconds
- **Monthly (30 days)**: `2592000.0` seconds

### Managing Recurring Schedules

- To stop: Use `cancel_scheduled_rebalancing.cdc`
- To modify: Cancel and reschedule with new parameters
- Monitor status: Use `get_scheduled_rebalancing.cdc`

## Transaction Statuses

| Status | Description |
|--------|-------------|
| **Scheduled** | Waiting for execution time |
| **Executed** | Successfully completed |
| **Canceled** | Manually canceled by user |
| **Unknown** | Historical transaction (status pruned) |

## Best Practices

### 1. Start with Estimates

Always estimate costs before scheduling:

```bash
# Get estimate
ESTIMATE=$(flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc ...)

# Add 20% buffer
FEE=$(echo "$ESTIMATE * 1.2" | bc)
```

### 2. Choose Appropriate Priority

- Use **Low** for cost savings on non-critical rebalancing
- Use **Medium** for standard scheduled rebalancing
- Use **High** only when timing is critical

### 3. Monitor Your Schedules

Regularly check scheduled transactions:

```bash
# Weekly check
flow scripts execute cadence/scripts/flow-vaults/get_all_scheduled_rebalancing.cdc \
  --arg Address:YOUR_ADDRESS
```

### 4. Test with One-Time First

Before setting up recurring:
1. Schedule a one-time rebalancing
2. Verify it executes correctly
3. Then schedule recurring if satisfied

### 5. Consider Gas Costs

For recurring schedules:
- Higher frequency = more fees
- Balance frequency with position needs
- Daily is often sufficient for most positions

## Troubleshooting

### "Insufficient fees" Error

**Solution**: Increase the `feeAmount` parameter. Use the estimate script with a buffer:

```bash
# Get estimate and add 20%
ESTIMATE=$(flow scripts execute estimate_rebalancing_cost.cdc ...)
FEE=$(python3 -c "print($ESTIMATE * 1.2)")
```

### "No AutoBalancer found" Error

**Solution**: Ensure the Tide has an associated AutoBalancer. Check:

```bash
flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:YOUR_TIDE_ID
```

### "Rebalancing already scheduled" Error

**Solution**: Cancel the existing schedule first:

```bash
flow transactions send cadence/transactions/flow-vaults/cancel_scheduled_rebalancing.cdc \
  --arg UInt64:YOUR_TIDE_ID
```

### Scheduled Transaction Not Executing

**Possible causes**:
1. **Handler capability broken**: Reinstall if needed
2. **Insufficient priority**: Low priority may be delayed
3. **Network congestion**: High priority guarantees execution
4. **AutoBalancer conditions**: Check thresholds if `force = false`

## Events

Monitor these events for scheduled rebalancing:

### RebalancingScheduled

Emitted when a schedule is created:

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
```

### RebalancingExecuted

Emitted when rebalancing executes:

```cadence
event RebalancingExecuted(
    tideID: UInt64,
    scheduledTransactionID: UInt64,
    timestamp: UFix64
)
```

### RebalancingCanceled

Emitted when a schedule is canceled:

```cadence
event RebalancingCanceled(
    tideID: UInt64,
    scheduledTransactionID: UInt64,
    feesReturned: UFix64
)
```

## Advanced Topics

### Custom Rebalancing Logic

The system uses the AutoBalancer's `rebalance()` method. The `force` parameter controls behavior:

- `force = false`: Respects threshold settings (recommended)
- `force = true`: Always rebalances (use with caution)

### Integration with External Systems

You can monitor events and build:
- Notification systems (Discord, Telegram bots)
- Analytics dashboards
- Automated alerting for failed executions

### Multi-Tide Management

Schedule different intervals for different Tides based on:
- Position size (larger = more frequent)
- Volatility (higher = more frequent)
- Risk tolerance
- Gas budget

## Security Considerations

1. **Authorization**: Only the Tide owner can schedule rebalancing
2. **Fees**: Fees are non-refundable if execution completes
3. **Handler Capabilities**: Stored securely in your account storage
4. **Cancellation**: Only you can cancel your scheduled transactions

## FAQ

**Q: Can I schedule multiple rebalancing operations for the same Tide?**
A: No, only one schedule per Tide. Cancel existing schedule to create a new one.

**Q: What happens if I don't have enough funds for recurring rebalancing?**
A: Each execution is independent. If you run out of funds, future executions won't happen.

**Q: Can I change the interval of a recurring schedule?**
A: No, you must cancel and reschedule with the new interval.

**Q: What's the minimum time I can schedule in the future?**
A: At least one second in the future, but practical minimum is ~10 seconds.

**Q: Do I get refunded if the rebalancing doesn't happen?**
A: Partial refunds only on cancellation. Executed transactions are not refunded.

## Support & Resources

- **Flow Docs**: https://developers.flow.com/
- **FLIP 330**: https://github.com/onflow/flips/pull/330
- **Tidal Repo**: https://github.com/yourusername/tidal-sc
- **Discord**: [Your Discord Link]

## Example Scripts

### Daily Rebalancing Setup Script

```bash
#!/bin/bash

TIDE_ID=1
TOMORROW=$(date -d "tomorrow 00:00:00" +%s)

# Estimate
ESTIMATE=$(flow scripts execute cadence/scripts/flow-vaults/estimate_rebalancing_cost.cdc \
  --arg UFix64:${TOMORROW}.0 \
  --arg UInt8:1 \
  --arg UInt64:500 \
  --json | jq -r '.flowFee')

# Add buffer
FEE=$(python3 -c "print(${ESTIMATE} * 1.2)")

# Schedule
flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
  --arg UInt64:${TIDE_ID} \
  --arg UFix64:${TOMORROW}.0 \
  --arg UInt8:1 \
  --arg UInt64:500 \
  --arg UFix64:${FEE} \
  --arg Bool:false \
  --arg Bool:true \
  --arg UFix64:86400.0

echo "Scheduled daily rebalancing for Tide #${TIDE_ID}"
```

---

**Last Updated**: November 10, 2025
**Version**: 1.0.0


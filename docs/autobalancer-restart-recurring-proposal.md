# AutoBalancer Recovery via Schedule Capability

## Problem Statement

When an `AutoBalancer` is configured for recurring rebalancing, its `executeTransaction` function contains an internal check:

```cadence
let isInternallyManaged = self.borrowScheduledTransaction(id: id) != nil
if self._recurringConfig != nil && isInternallyManaged {
    self.scheduleNextRebalance(...)
}
```

This `isInternallyManaged` check determines whether a scheduled transaction was initiated by the AutoBalancer itself. Externally-scheduled transactions (e.g., those initiated by the Supervisor for recovery) are treated as "fire once" - they execute the rebalance but don't trigger the AutoBalancer to self-schedule its next execution.

This design (from PR #45 by @sisyphusSmiling) was intentional: "When externally-managed scheduled transactions are executed, it's treated as non-recurring even if `recurringConfig` is non-nil to support scheduling execution by external logic and handling."

However, for the Supervisor's recovery mechanism, we need stuck AutoBalancers to resume their self-scheduling cycle after recovery.

## Solution: Schedule Capability

Instead of modifying DeFiActions to add a `restartRecurring` flag, we use the existing `Schedule` entitlement to allow the Supervisor to directly call `scheduleNextRebalance()` on stuck AutoBalancers.

### How It Works

1. **AutoBalancer Registration**

   When a Tide is created, the AutoBalancer issues TWO capabilities:
   - `Execute` capability - for FlowTransactionScheduler to execute transactions
   - `Schedule` capability - for Supervisor to directly call `scheduleNextRebalance()`

   ```cadence
   // In FlowVaultsAutoBalancers._initNewAutoBalancer():
   let handlerCap = self.account.capabilities.storage
       .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(storagePath)

   let scheduleCap = self.account.capabilities.storage
       .issue<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>(storagePath)

   FlowVaultsSchedulerRegistry.register(tideID: uniqueID.id, handlerCap: handlerCap, scheduleCap: scheduleCap)
   ```

2. **Supervisor Recovery**

   When the Supervisor detects a stuck tide, it uses the `Schedule` capability to directly call `scheduleNextRebalance()`:

   ```cadence
   // In Supervisor.executeTransaction():
   let scheduleCap = FlowVaultsSchedulerRegistry.getScheduleCap(tideID: tideID)
   let autoBalancerRef = scheduleCap!.borrow()!
   let scheduleError = autoBalancerRef.scheduleNextRebalance(whileExecuting: nil)
   
   if scheduleError == nil {
       FlowVaultsSchedulerRegistry.dequeuePending(tideID: tideID)
       emit TideRecovered(tideID: tideID)
   }
   ```

### Advantages

1. **No changes to DeFiActions** - The recovery mechanism works with the existing `Schedule` entitlement without adding new flags or modifying `executeTransaction()`.

2. **Proper self-scheduling** - Calling `scheduleNextRebalance()` directly creates a scheduled transaction in the AutoBalancer's own `_scheduledTransactions` map, making `isInternallyManaged` return true for subsequent executions.

3. **Uses AutoBalancer's fee source** - The AutoBalancer schedules using its configured `txnFunder`, which is appropriate since:
   - Both Supervisor and AutoBalancer use the same fund source (contract account's FlowToken vault)
   - By the time Supervisor runs for recovery, the fund source should be refunded (that's why recovery is happening)

4. **Simpler Supervisor** - No need to track recovery schedules in the Supervisor; the AutoBalancer manages its own schedules.

## Architecture Summary

```
┌────────────────────────────────────────────────────────────────┐
│                    AutoBalancer Creation                        │
├────────────────────────────────────────────────────────────────┤
│ 1. AutoBalancer created with recurringConfig                   │
│ 2. Two capabilities issued:                                    │
│    - Execute cap (for FlowTransactionScheduler)               │
│    - Schedule cap (for Supervisor recovery)                   │
│ 3. Both registered in FlowVaultsSchedulerRegistry              │
│ 4. AutoBalancer.scheduleNextRebalance(nil) starts chain       │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│                    Normal Operation                             │
├────────────────────────────────────────────────────────────────┤
│ 1. Scheduled transaction fires                                  │
│ 2. FlowTransactionScheduler calls AutoBalancer.executeTransaction() │
│ 3. isInternallyManaged = true (ID in AutoBalancer's map)       │
│ 4. AutoBalancer.scheduleNextRebalance() schedules next         │
│ 5. Cycle continues perpetually                                  │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│                    Failure Scenario                             │
├────────────────────────────────────────────────────────────────┤
│ 1. AutoBalancer executes successfully                          │
│ 2. scheduleNextRebalance() fails (e.g., insufficient fees)     │
│ 3. FailedRecurringSchedule event emitted                       │
│ 4. Tide becomes "stuck" - no active schedule, overdue          │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│                    Supervisor Recovery                          │
├────────────────────────────────────────────────────────────────┤
│ 1. Supervisor scans registered tides                           │
│ 2. Detects stuck tides via isStuckTide() check:               │
│    - Has recurringConfig                                       │
│    - No active schedule                                        │
│    - Next expected execution time is in the past              │
│ 3. Gets Schedule capability from Registry                      │
│ 4. Directly calls AutoBalancer.scheduleNextRebalance(nil)      │
│ 5. AutoBalancer schedules itself using its own fee source      │
│ 6. Normal operation resumes                                     │
└────────────────────────────────────────────────────────────────┘
```

## Events

The Supervisor emits these events during recovery:

- `StuckTideDetected(tideID: UInt64)` - When a stuck tide is identified
- `TideRecovered(tideID: UInt64)` - When `scheduleNextRebalance()` succeeds
- `TideRecoveryFailed(tideID: UInt64, error: String)` - When recovery fails

## Fee Source Considerations

Both Supervisor and AutoBalancer use the same fund source (the FlowVaultsStrategies contract account's FlowToken vault). This means:

1. If the account is drained, BOTH fail to schedule
2. If the account is refunded, BOTH can schedule again

The recovery flow assumes:
1. Something caused tides to become stuck (e.g., fund drain)
2. The issue is resolved (e.g., fund refund)
3. Supervisor is manually restarted or scheduled
4. Supervisor detects stuck tides and recovers them

## Related Changes

### FlowVaultsSchedulerRegistry

Added storage for Schedule capabilities:

```cadence
access(self) var scheduleCaps: {UInt64: Capability<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>}

access(account) fun register(
    tideID: UInt64,
    handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
    scheduleCap: Capability<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>
)

access(account) view fun getScheduleCap(tideID: UInt64): Capability<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>?
```

### FlowVaultsAutoBalancers

Issues Schedule capability during initialization:

```cadence
let scheduleCap = self.account.capabilities.storage
    .issue<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>(storagePath)
```

### FlowVaultsScheduler

Simplified Supervisor that directly calls `scheduleNextRebalance()`:

```cadence
let scheduleCap = FlowVaultsSchedulerRegistry.getScheduleCap(tideID: tideID)
let autoBalancerRef = scheduleCap!.borrow()!
let scheduleError = autoBalancerRef.scheduleNextRebalance(whileExecuting: nil)
```

### DeFiActions (FlowCreditMarket/FlowActions)

Only the fee buffer fix (5% margin) was kept. No `restartRecurring` flag was added.

```cadence
// In scheduleNextRebalance():
let feeWithMargin = estimate.flowFee! * 1.05  // 5% buffer for estimation variance
```

## Test Coverage

The following tests verify the recovery mechanism:

1. **testInsufficientFundsAndRecovery** - Creates 5 tides, drains funds to cause failures, refunds, and verifies Supervisor recovers all tides
2. **testFailedTideCannotRecoverWithoutSupervisor** - Verifies stuck tides stay stuck without Supervisor intervention
3. **testStuckTideDetectionLogic** - Verifies `isStuckTide()` correctly identifies stuck vs healthy tides
4. **testSupervisorDoesNotDisruptHealthyTides** - Verifies Supervisor doesn't interfere with healthy self-scheduling tides

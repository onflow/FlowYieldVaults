# AutoBalancer `restartRecurring` Flag Proposal

## Summary

This document proposes adding a `restartRecurring` flag to the `AutoBalancer.executeTransaction()` method in `DeFiActions.cdc` to support Supervisor recovery scenarios while preserving the original design intent for externally-scheduled transactions.

## Background

### Original Design (PR #45)

In [FlowActions PR #45](https://github.com/onflow/FlowActions/pull/45) ("Add scheduled transaction functionality to AutoBalancer"), @sisyphusSmiling introduced the concept of **internally-managed** vs **externally-managed** scheduled transactions:

> "When externally-managed scheduled transactions are executed, it's treated as non-recurring even if `recurringConfig` is non-nil to support scheduling execution by external logic and handling"

The implementation uses an `isInternallyManaged` check:

```cadence
let isInternallyManaged = self.borrowScheduledTransaction(id: id) != nil
if self._recurringConfig != nil && isInternallyManaged {
    self.scheduleNextRebalance(whileExecuting: id)
}
```

**Design Intent:**
- **Internally-managed** transactions (scheduled by AutoBalancer via `scheduleNextRebalance()`) are tracked in `self._scheduledTransactions` and will auto-reschedule
- **Externally-managed** transactions (scheduled by external entities) are NOT in `_scheduledTransactions` and are treated as "fire once" to avoid interfering with external scheduling logic

### The Problem: Supervisor Recovery

In the FlowVaults Scheduler architecture, the **Supervisor** is responsible for recovering stuck tides (AutoBalancers that failed to self-reschedule, e.g., due to insufficient funds).

When the Supervisor seeds a stuck tide:
1. It schedules directly via `FlowTransactionScheduler.schedule()` 
2. The scheduled transaction ID is stored in `Supervisor.scheduledTransactions`, NOT `AutoBalancer._scheduledTransactions`
3. When executed, `isInternallyManaged` returns `false`
4. `scheduleNextRebalance()` is NOT called
5. The tide executes ONCE but does NOT resume self-scheduling
6. The tide becomes stuck again immediately

**Note:** The original SchedulerManager resource has been merged into Supervisor for simplicity.

**Reference Commit:** The issue was discovered during testing in the `scheduled-rebalancing` branch of [FlowVaults-sc](https://github.com/onflow/FlowVaults-sc).

## Proposed Solution

Add a `restartRecurring` flag to the `data` parameter that can be passed when scheduling a transaction. When `true`, the AutoBalancer will call `scheduleNextRebalance()` regardless of whether the transaction was internally or externally managed.

### Code Changes

**In `DeFiActions.cdc` (`executeTransaction` method):**

```cadence
access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
    let dataDict = data as? {String: AnyStruct} ?? {}
    let force = dataDict["force"] as? Bool ?? self._recurringConfig?.forceRebalance as? Bool ?? false
    let restartRecurring = dataDict["restartRecurring"] as? Bool ?? false  // NEW FLAG
    
    self.rebalance(force: force)

    // If configured as recurring, schedule next execution if:
    // 1. This transaction is internally managed (normal self-scheduling), OR
    // 2. The caller explicitly requested to restart recurring (recovery scenario)
    if self._recurringConfig != nil {
        let isInternallyManaged = self.borrowScheduledTransaction(id: id) != nil
        if isInternallyManaged || restartRecurring {
            let err = self.scheduleNextRebalance(whileExecuting: id)
            if err != nil {
                emit FailedRecurringSchedule(
                    whileExecuting: id,
                    balancerUUID: self.uuid,
                    address: self.owner?.address,
                    error: err!,
                    uniqueID: self.uniqueID?.id
                )
            }
        }
    }
    self._cleanupScheduledTransactions()
}
```

**In `FlowVaultsScheduler.cdc` (Supervisor seeding logic):**

```cadence
// When Supervisor seeds a stuck tide, pass restartRecurring: true
let data: {String: AnyStruct} = {
    "force": forceChild,
    "restartRecurring": true  // Signal AutoBalancer to resume self-scheduling
}
```

### Benefits

1. **Preserves Original Design**: External schedulers that want "fire once" behavior get it by default
2. **Enables Recovery**: Supervisor can explicitly request recurring restart
3. **Backward Compatible**: Existing code that doesn't pass `restartRecurring` works unchanged
4. **Explicit Intent**: The flag makes the intent clear in the code

### Alternative Considered

An alternative fix was to simply remove the `isInternallyManaged` check entirely:

```cadence
// Always reschedule if recurring config exists
if self._recurringConfig != nil {
    self.scheduleNextRebalance(whileExecuting: id)
}
```

This was implemented temporarily in commit `1fedc9e` but changes behavior for ALL external schedulers, which may not be desired.

## References

- **Original PR**: [FlowActions PR #45](https://github.com/onflow/FlowActions/pull/45) - "Add scheduled transaction functionality to AutoBalancer"
- **Original Commit**: [`c76e0fe`](https://github.com/onflow/FlowActions/commit/c76e0fee0434c9590923a40cf85938845cf88e16) - Introduced `isInternallyManaged` check
- **Temporary Fix Commit**: `1fedc9e` in FlowActions (local) - Removed `isInternallyManaged` check entirely
- **FlowVaults-sc Branch**: `scheduled-rebalancing` - Where the Supervisor recovery was implemented and the issue discovered

## Implementation Status

- [x] Create branch in FlowActions with proposed fix
  - Branch: `fix/restart-recurring-flag`
  - Commit: [`8b33ace`](https://github.com/onflow/FlowActions/commit/8b33ace) - "Add restartRecurring flag to AutoBalancer.executeTransaction()"
  - Commit: [`66c8b49`](https://github.com/onflow/FlowActions/commit/66c8b49) - "Fix fee margin: add 5% buffer to scheduling fee estimation"
- [x] Update FlowVaultsScheduler to pass `restartRecurring: true` when seeding
- [x] Update tests to verify behavior (all tests pass)
- [x] Open PR in FlowActions for review
  - **PR: [onflow/FlowActions#68](https://github.com/onflow/FlowActions/pull/68)**
- [x] Merge SchedulerManager into Supervisor for simplified architecture
  - Commit: [`6134b43`](https://github.com/onflow/FlowVaults-sc/commit/6134b43) - "refactor: Merge SchedulerManager into Supervisor"

## Test Scenario

The fix enables this test scenario to pass:

1. Create 10 tides, let them run 3 rounds (30 executions)
2. Drain FLOW from the fee vault
3. Tides fail to reschedule, all 10 become stuck
4. Refund the account
5. Start Supervisor with `scanForStuck: true`
6. Supervisor detects and seeds all 10 stuck tides
7. **Expected**: Tides resume self-scheduling, execute 3+ more times each
8. **Expected**: All tides have active schedules, none are stuck

---

*Document created: November 27, 2025*
*Author: AI-assisted development session*


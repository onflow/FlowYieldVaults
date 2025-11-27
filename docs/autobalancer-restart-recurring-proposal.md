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

## Why `restartRecurring` is Necessary (Not Just `isInternallyManaged`)

### How AutoBalancer Tracks Its Own Schedules

When an AutoBalancer schedules itself via `scheduleNextRebalance()`:

```cadence
// Inside AutoBalancer.scheduleNextRebalance():
let txn <- FlowTransactionScheduler.schedule(...)
let txnID = txn.id
self._scheduledTransactions[txnID] <-! txn  // Stored in AutoBalancer's internal map
```

Later, when `executeTransaction()` runs:

```cadence
let isInternallyManaged = self.borrowScheduledTransaction(id: id) != nil
// Returns TRUE because the transaction ID exists in AutoBalancer's _scheduledTransactions map
```

### How Supervisor Seeds a Stuck Tide

When the Supervisor seeds a stuck tide:

```cadence
// Inside Supervisor.scheduleRecovery():
let txn <- FlowTransactionScheduler.schedule(
    handlerCap: autoBalancerCap,  // Points to AutoBalancer
    data: {"restartRecurring": true},
    ...
)
self.scheduledTransactions[tideID] <-! txn  // Stored in SUPERVISOR's map, NOT AutoBalancer's
```

When this transaction executes on the AutoBalancer:

```cadence
let isInternallyManaged = self.borrowScheduledTransaction(id: id) != nil
// Returns FALSE because the transaction ID is NOT in AutoBalancer's _scheduledTransactions
// It's in Supervisor's scheduledTransactions instead
```

### The Problem

Without `restartRecurring`:
1. Supervisor seeds stuck tide -> transaction stored in Supervisor's map
2. Transaction executes on AutoBalancer
3. `isInternallyManaged = false` (ID not in AutoBalancer's map)
4. `scheduleNextRebalance()` is NOT called
5. Tide executes once but does NOT resume self-scheduling
6. Tide becomes stuck again immediately

### The Solution

With `restartRecurring: true`:
1. Supervisor passes `{"restartRecurring": true}` in transaction data
2. Transaction executes on AutoBalancer
3. Even though `isInternallyManaged = false`, `restartRecurring = true`
4. `scheduleNextRebalance()` IS called
5. AutoBalancer creates a NEW scheduled transaction in ITS OWN `_scheduledTransactions` map
6. Tide resumes normal self-scheduling cycle

### Why Not Just Remove `isInternallyManaged`?

The original design (PR #45) intentionally treats external schedules as "fire once" to:
- Allow external schedulers to have full control over timing
- Prevent interference between external scheduling logic and AutoBalancer's native scheduling
- Support one-off manual rebalancing triggers

The `restartRecurring` flag preserves this design while enabling the specific recovery use case.

### Why Doesn't Supervisor Just Call `scheduleNextRebalance()` Directly?

The most elegant solution would be for the Supervisor to call `AutoBalancer.scheduleNextRebalance()` directly, which would properly create a schedule in the AutoBalancer's own `_scheduledTransactions` map, making `isInternallyManaged` true.

**The answer: The Supervisor doesn't have the required entitlement.**

`scheduleNextRebalance()` requires the `Schedule` entitlement:

```cadence
access(Schedule) fun scheduleNextRebalance(whileExecuting: UInt64?): String?
```

But the Supervisor only has an `Execute` entitlement capability:

```cadence
// In FlowVaultsSchedulerRegistry, the handlerCap is:
Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
```

The `Execute` entitlement only allows calling `executeTransaction()`, not `scheduleNextRebalance()`.

**Why not issue a `Schedule` capability?**

The `Schedule` entitlement is intentionally restricted. Issuing it broadly would allow any holder to schedule transactions on behalf of the AutoBalancer, potentially:
- Draining the AutoBalancer's fee vault
- Creating unwanted schedules
- Interfering with the AutoBalancer's timing

The `restartRecurring` flag is a safer approach: the Supervisor provides ONE seed execution (paying its own fees), and during that execution, the AutoBalancer uses ITS OWN `Schedule` entitlement to call `scheduleNextRebalance()` internally.

### Why Can't We Just "Set `isInternallyManaged` to True"?

A related question: instead of adding a new `restartRecurring` flag, why can't the Supervisor just set `isInternallyManaged` to `true` when it seeds a stuck tide?

**The answer: `isInternallyManaged` is NOT a settable flag - it's a runtime lookup.**

```cadence
let isInternallyManaged = self.borrowScheduledTransaction(id: id) != nil
```

This line checks: "Does this transaction ID exist in MY `_scheduledTransactions` map?"

The AutoBalancer's `_scheduledTransactions` is a **private resource dictionary** that only the AutoBalancer itself can write to:

```cadence
access(self) let _scheduledTransactions: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}
```

When the Supervisor schedules a transaction:
1. It calls `FlowTransactionScheduler.schedule()` which returns a `@ScheduledTransaction` resource
2. The Supervisor stores this resource in **its own** `scheduledTransactions` map
3. The Supervisor **cannot** store it in the AutoBalancer's `_scheduledTransactions` because:
   - It's `access(self)` (private to AutoBalancer)
   - The Supervisor only has an `Execute` entitlement capability, not storage access

**Even if we wanted to, there's no way to make the AutoBalancer "think" a Supervisor-created schedule is internally managed** - the transaction resource physically exists in Supervisor's storage, not AutoBalancer's storage.

This is why `restartRecurring` is the correct solution: it's an explicit signal passed in the transaction data that tells the AutoBalancer "I know I'm external, but please resume your self-scheduling cycle after this execution."

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


# PR Review Changes Summary

## Overview

This document summarizes all changes made from commit `2479635` (PR review acknowledgment) to `58b70af` (final Schedule capability implementation) to address the feedback from @sisyphusSmiling on the scheduled-rebalancing PR.

**Total commits**: 28 commits  
**Files changed**: 31 files  
**Lines changed**: +2,043 / -2,031

**Related PRs**:
- FlowActions (fee buffer fix): https://github.com/onflow/FlowActions/pull/68

---

## Core Architecture Change

### Before (Old Approach)
- `SchedulerManager` and `Supervisor` were separate resources
- Supervisor scheduled recovery transactions via `FlowTransactionScheduler`
- AutoBalancers required external wrapper for scheduling
- Complex transaction tracking with `scheduledTransactions` and `scheduleData` maps
- `MAX_BATCH_SIZE = 50`

### After (New Approach)
- **Native AutoBalancer self-scheduling**: AutoBalancers now schedule themselves via `scheduleNextRebalance()` at creation
- **Merged SchedulerManager into Supervisor**: Simplified architecture
- **Schedule capability for recovery**: Supervisor uses `DeFiActions.Schedule` entitlement to directly call `scheduleNextRebalance()` on stuck AutoBalancers
- **No changes to DeFiActions needed** (except 5% fee buffer fix)
- `MAX_BATCH_SIZE = 5` (reduced for better gas management)

---

## Contract Changes

### FlowVaultsScheduler.cdc

**Lines changed**: -786 / +266 (significantly simplified)

#### Removed
- `SchedulerManager` resource entirely
- `SchedulerManagerStoragePath` and `SchedulerManagerPublicPath`
- `registerTide()` and `unregisterTide()` functions
- `RebalancingScheduleInfo` and `RebalancingScheduleData` structs
- Complex recovery transaction tracking
- `RebalancingScheduled`, `RebalancingCanceled`, `SupervisorSeededTide` events

#### Added/Changed
- **Simplified Supervisor** that:
  - Detects stuck tides via `isStuckTide()` check
  - Uses `Schedule` capability to directly call `scheduleNextRebalance()`
  - No longer tracks recovery transactions
- New events: `TideRecovered`, `TideRecoveryFailed`, `StuckTideDetected`, `SupervisorRescheduled`
- `ensureSupervisorConfigured()` changed to `access(all)` (was `access(account)`)

### FlowVaultsSchedulerRegistry.cdc

**Lines changed**: +82 changes

#### Added
- `scheduleCaps` dictionary: stores `DeFiActions.Schedule` capabilities per tide
- `register()` now accepts both `handlerCap` and `scheduleCap`
- `getScheduleCap()` getter for Supervisor to use
- `getPendingTideIDsPaginated()` for paginated access to pending queue
- `getHandlerCapability()` public version for transactions

#### Changed
- `MAX_BATCH_SIZE` reduced from `50` to `5`
- `getHandlerCap()` restricted to `access(account)`
- Improved capability validation in `register()`

### FlowVaultsAutoBalancers.cdc

**Lines changed**: +109 changes

#### Added
- `hasActiveSchedule(id)`: Checks if AutoBalancer has an active scheduled transaction
- `isStuckTide(id)`: Detects if a tide is stuck (has recurring config, no active schedule, overdue)
- Issues `Schedule` capability during registration for Supervisor recovery
- Calls `scheduleNextRebalance(nil)` at creation to start self-scheduling chain

#### Changed
- Now imports `FlowVaultsSchedulerRegistry` instead of `FlowVaultsScheduler`
- Registration happens via Registry, not Scheduler
- `_borrowAutoBalancer()` returns reference with `DeFiActions.Schedule` entitlement

### FlowVaultsStrategies.cdc

**Lines changed**: +81 changes

- Added `_createRecurringConfig()` to create proper `AutoBalancerRecurringConfig`
- Strategies now pass recurring config to AutoBalancer at creation
- Added `_createTxnFunder()` for fee source capability

---

## New Scripts

| Script | Purpose |
|--------|---------|
| `get_flow_balance.cdc` | Get FLOW balance of an account (for testing fund drain) |
| `get_pending_tides_paginated.cdc` | Paginated access to pending queue |
| `get_registered_tide_count.cdc` | Count of registered tides |
| `has_active_schedule.cdc` | Check if tide has active scheduled transaction |
| `is_stuck_tide.cdc` | Check if tide is stuck (needs recovery) |

---

## Removed Transactions

| Transaction | Reason |
|-------------|--------|
| `cancel_scheduled_rebalancing.cdc` | SchedulerManager removed; AutoBalancers manage own schedules |
| `schedule_rebalancing.cdc` | No longer manually schedule; AutoBalancers self-schedule |
| `setup_scheduler_manager.cdc` | SchedulerManager merged into Supervisor |
| `reset_scheduler_manager.cdc` | SchedulerManager removed |

---

## New Transaction

| Transaction | Purpose |
|-------------|---------|
| `drain_flow.cdc` | Test helper to drain FLOW and simulate insufficient funds |

---

## Test Changes

### scheduled_rebalance_scenario_test.cdc
**Tests for core native scheduling behavior**

| Test | Description |
|------|-------------|
| `testRegistryReceivesTideRegistrationAtInit` | Verifies tide is registered during creation |
| `testSingleAutoBalancerThreeExecutions` | Single tide executes exactly 3 times with balance changes |
| `testThreeTidesNineExecutions` | 3 tides x 3 rounds = 9 total executions |
| `testFiveTidesContinueWithoutSupervisor` | Verifies tides continue perpetually without Supervisor |
| `testFailedTideCannotRecoverWithoutSupervisor` | Drains funds, verifies tides become stuck, stay stuck without Supervisor |

### scheduled_supervisor_test.cdc
**Tests for Supervisor recovery mechanism**

| Test | Description |
|------|-------------|
| `testAutoRegisterAndSupervisor` | Basic registration and Supervisor setup |
| `testMultiTideNativeScheduling` | Multiple tides all self-schedule natively |
| `testRecurringRebalancingThreeRuns` | Verifies 3 rounds of execution per tide |
| `testMultiTideIndependentExecution` | Tides execute independently |
| `testPaginationStress` | 18 tides (3 x MAX_BATCH_SIZE + 3), each executes 3+ times |
| `testSupervisorDoesNotDisruptHealthyTides` | Supervisor doesn't interfere with healthy tides |
| `testStuckTideDetectionLogic` | Verifies `isStuckTide()` correctly identifies stuck vs healthy |
| `testInsufficientFundsAndRecovery` | **Comprehensive test**: 5 tides, drain funds, verify stuck, refund, Supervisor recovers all |

### scheduler_edge_cases_test.cdc
**Edge case tests**

| Test | Description |
|------|-------------|
| `testSupervisorDoubleSchedulingPrevented` | Can't double-schedule same tide for recovery |
| `testCapabilityReuse` | Capability correctly reused on re-registration |
| `testCloseTideUnregisters` | Closing tide properly unregisters from registry |
| `testMultipleUsersMultipleTides` | Multiple users with multiple tides all registered |
| `testHealthyTidesSelfSchedule` | Healthy tides continue self-scheduling without Supervisor |

### Key Testing Improvements
- **`Test.reset(to: snapshot)`**: Used for test isolation
- **Exact assertions**: `Test.assertEqual` instead of `>=` comparisons
- **Balance verification**: Track balance changes between executions
- **Stuck tide simulation**: Drain FLOW to cause failures, verify stuck state

---

## DeFiActions (FlowALP/FlowActions) Changes

**Branch**: `fix/restart-recurring-flag`  
**PR**: https://github.com/onflow/FlowActions/pull/68

### Final Changes (kept)
- **5% fee buffer**: `estimate.flowFee! * 1.05` for scheduling fee estimation variance
- **Nil-safe error handling**: `estimate.error ?? ""` instead of force-unwrap

### Reverted Changes
- `restartRecurring` flag was added then removed (replaced by Schedule capability approach)

---

## Documentation Added

| Document | Content |
|----------|---------|
| `pr_review_acknowledgment.md` | AI-assisted development learnings, policing agent proposal |
| `autobalancer-restart-recurring-proposal.md` | Full explanation of Schedule capability recovery mechanism |

---

## Architecture Diagrams

### Tide Creation Flow
```
1. User creates Tide via create_tide.cdc
2. FlowVaultsStrategies creates strategy with AutoBalancer
3. AutoBalancer created with recurringConfig
4. FlowVaultsAutoBalancers._initNewAutoBalancer():
   a. Saves AutoBalancer to storage
   b. Issues Execute capability (for FlowTransactionScheduler)
   c. Issues Schedule capability (for Supervisor recovery)
   d. Registers both caps with FlowVaultsSchedulerRegistry
   e. Calls scheduleNextRebalance(nil) to start chain
5. AutoBalancer self-schedules perpetually
```

### Normal Execution Flow
```
1. Scheduled transaction fires (FlowTransactionScheduler)
2. Calls AutoBalancer.executeTransaction()
3. isInternallyManaged = true (ID in AutoBalancer's _scheduledTransactions)
4. AutoBalancer.rebalance() executes
5. AutoBalancer.scheduleNextRebalance() schedules next
6. Cycle continues
```

### Failure & Recovery Flow
```
1. AutoBalancer fails to self-schedule (e.g., insufficient fees)
2. FailedRecurringSchedule event emitted
3. Tide becomes "stuck" (no active schedule, overdue)

Recovery:
4. Funds are refunded
5. Supervisor is scheduled/restarted
6. Supervisor.executeTransaction() runs:
   a. Scans registered tides
   b. Calls isStuckTide() for each
   c. For stuck tides: borrows Schedule capability
   d. Calls autoBalancer.scheduleNextRebalance(nil) directly
7. AutoBalancer resumes self-scheduling
```

---

## Access Control Summary

| Function | Access | Rationale |
|----------|--------|-----------|
| `ensureSupervisorConfigured()` | `access(all)` | Must be callable from setup transaction |
| `borrowSupervisor()` | `access(account)` | Internal use only |
| `enqueuePendingTide()` | `access(account)` | Prevents external manipulation |
| `getScheduleCap()` | `access(account)` | Only Supervisor should access |
| `getHandlerCap()` | `access(account)` | Internal scheduling use |
| `getHandlerCapability()` | `access(all)` | Public for external schedulers |

---

## Constants Changed

| Constant | Old Value | New Value | Reason |
|----------|-----------|-----------|--------|
| `MAX_BATCH_SIZE` | 50 | 5 | Better gas management, clearer testing |
| Fee margin | 0% | 5% | Handle estimation variance |

---

## Summary of Reviewer Feedback Addressed

1. **"Contracts do not actually result in recurring rebalances"** - Fixed by implementing native AutoBalancer self-scheduling via `scheduleNextRebalance()` at creation

2. **"Supervisor discontinues when pending queue is empty"** - Fixed; Supervisor now scans all registered tides for stuck ones, not just pending queue

3. **"Hybrid approach jeopardizes intent"** - Simplified to pure native approach; Supervisor only for recovery

4. **"Excessive complexity"** - Removed SchedulerManager, wrapper handlers, complex transaction tracking

5. **Access control concerns** - Tightened `getScheduleCap()`, `borrowSupervisor()`, `enqueuePendingTide()` to `access(account)`

6. **"Register the ID with the registry"** - Done; all tides registered at creation

7. **"Call AutoBalancer.scheduleNextRebalance(nil)"** - Done; called at tide creation to start chain

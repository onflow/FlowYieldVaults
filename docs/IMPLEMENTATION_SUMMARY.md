# Scheduled Rebalancing Implementation Summary

## Overview

Autonomous scheduled rebalancing for FlowVaults Tides using Flow's native transaction scheduler (FLIP 330).

## Branch Information

**Branch**: `scheduled-rebalancing`  
**Last Updated**: November 26, 2025

## Architecture

### Key Design Principles

1. **Atomic Initial Scheduling**: Tide creation atomically registers and schedules first execution
2. **No Wrapper**: Direct capability to AutoBalancer (RebalancingHandler removed)
3. **Self-Scheduling AutoBalancers**: AutoBalancers chain their own subsequent executions
4. **Recovery-Only Supervisor**: Processes bounded pending queue, not all tides

### Component Design

```
FlowVaults Contract Account  
    |
    +-- FlowVaultsScheduler
    |       +-- SchedulerManager (tracks scheduled transactions)
    |       +-- Supervisor (recovery handler for failed schedules)
    |
    +-- FlowVaultsSchedulerRegistry
    |       +-- tideRegistry: {UInt64: Bool}
    |       +-- handlerCaps: {UInt64: Capability<AutoBalancer>}
    |       +-- pendingQueue: {UInt64: Bool}  (bounded by MAX_BATCH_SIZE=50)
    |       +-- supervisorCap
    |
    +-- FlowVaultsAutoBalancers
            +-- AutoBalancer (per Tide) implements TransactionHandler
```

### Execution Flow

1. **Tide Creation** (atomic):
   - User creates Tide via `create_tide.cdc`
   - Strategy creates AutoBalancer in `_initNewAutoBalancer()`
   - `registerTide()` atomically:
     - Issues capability directly to AutoBalancer
     - Registers in FlowVaultsSchedulerRegistry
     - Schedules first execution
   - If any step fails, entire transaction reverts

2. **Scheduled Execution**:
   - FlowTransactionScheduler triggers at scheduled time
   - Calls `AutoBalancer.executeTransaction()`
   - AutoBalancer.rebalance() executes
   - AutoBalancer self-schedules next execution (if configured with recurringConfig)

3. **Recovery** (Supervisor):
   - Processes `getPendingTideIDs()` (MAX 50 per run)
   - Schedules tides that failed to self-schedule
   - Self-reschedules if pending work remains

## Files

### Core Contracts
- **`FlowVaultsScheduler.cdc`** (~730 lines)
  - SchedulerManager resource
  - Supervisor resource (recovery handler)
  - Atomic registration with initial scheduling
  
- **`FlowVaultsSchedulerRegistry.cdc`** (~155 lines)
  - Registry storage (separate contract)
  - Pending queue with MAX_BATCH_SIZE pagination
  - Events: TideRegistered, TideUnregistered, TideEnqueuedPending, TideDequeuedPending

### Transactions
- `schedule_rebalancing.cdc` - Manual schedule (after canceling auto-schedule)
- `cancel_scheduled_rebalancing.cdc` - Cancel and get refund
- `setup_scheduler_manager.cdc` - Initialize SchedulerManager
- `setup_supervisor.cdc` - Initialize Supervisor
- `schedule_supervisor.cdc` - Schedule Supervisor for recovery
- `enqueue_pending_tide.cdc` - Manually enqueue for recovery

### Scripts
- `get_scheduled_rebalancing.cdc` - Query specific tide's schedule
- `get_all_scheduled_rebalancing.cdc` - List all scheduled rebalancing
- `get_registered_tide_ids.cdc` - Get registered tide IDs
- `get_pending_count.cdc` - Check pending queue size
- `estimate_rebalancing_cost.cdc` - Estimate fees
- `has_wrapper_cap_for_tide.cdc` - Check if handler cap exists (renamed from wrapper)

### Tests
- `scheduled_supervisor_test.cdc` - Supervisor and multi-tide tests
- `scheduled_rebalance_integration_test.cdc` - Integration tests
- `scheduled_rebalance_scenario_test.cdc` - Scenario-based tests
- `scheduler_edge_cases_test.cdc` - Edge case tests

## Key Features

### Automatic Scheduling at Tide Creation
- No manual setup required
- First rebalancing scheduled atomically with tide creation
- Fails safely - reverts entire transaction if scheduling fails

### Self-Scheduling AutoBalancers
- AutoBalancers with `recurringConfig` chain their own executions
- No central coordinator needed for normal operation
- Each AutoBalancer manages its own schedule independently

### Paginated Recovery (Supervisor)
- MAX_BATCH_SIZE = 50 tides per Supervisor run
- Only processes pending queue (not all registered tides)
- Self-reschedules if more work remains

### Events
```cadence
// FlowVaultsScheduler
event RebalancingScheduled(tideID, scheduledTransactionID, timestamp, priority, isRecurring, ...)
event RebalancingCanceled(tideID, scheduledTransactionID, feesReturned)
event SupervisorSeededTide(tideID, scheduledTransactionID, timestamp)

// FlowVaultsSchedulerRegistry
event TideRegistered(tideID, handlerCapValid)
event TideUnregistered(tideID, wasInPendingQueue)
event TideEnqueuedPending(tideID, pendingQueueSize)
event TideDequeuedPending(tideID, pendingQueueSize)
```

## Test Coverage

| Test | Description |
|------|-------------|
| `testAutoRegisterAndSupervisor` | Tide creation auto-registers and schedules |
| `testMultiTideFanOut` | 3 tides all scheduled by Supervisor |
| `testRecurringRebalancingThreeRuns` | Single tide executes 3+ times |
| `testMultiTideIndependentExecution` | 3 tides execute independently |
| `testPaginationStress` | 60 tides (>MAX_BATCH_SIZE) all scheduled atomically |
| `testSupervisorRecoveryOfFailedReschedule` | Recovery flow works |
| `testDoubleSchedulingSameTideFails` | Duplicate scheduling prevented |
| `testCloseTideWithPendingSchedule` | Cleanup on tide close |

## Security

1. **Access Control**:
   - `getSupervisorCap()` - `access(account)`
   - `getHandlerCap()` - `access(account)`
   - `enqueuePending()` - `access(account)`
   - Registration/unregistration only from FlowVaultsAutoBalancers

2. **Atomic Operations**:
   - Tide creation + registration + scheduling is atomic
   - Failure at any step reverts the entire transaction

3. **Bounded Operations**:
   - Supervisor processes MAX 50 tides per execution
   - Prevents compute limit exhaustion

## Changelog

### Version 2.0.0 (November 26, 2025)
- Removed RebalancingHandler wrapper
- Atomic initial scheduling at tide registration
- Paginated Supervisor with pending queue
- Self-scheduling AutoBalancers
- Moved registration to FlowVaultsAutoBalancers
- Added comprehensive events

### Version 1.0.0 (November 10, 2025)
- Initial implementation
- Central Supervisor scanning all tides
- RebalancingHandler wrapper

---

**Status**: Implementation complete, tests passing  
**Last Updated**: November 26, 2025

# Scheduled Rebalancing Implementation Summary

## Overview

Autonomous scheduled rebalancing for FlowYieldVaults YieldVaults using Flow's native transaction scheduler (FLIP 330).

## Branch Information

**Branch**: `scheduled-rebalancing`  
**Last Updated**: November 26, 2025

## Architecture

### Key Design Principles

1. **Atomic Initial Scheduling**: YieldVault creation atomically registers and schedules first execution
2. **No Wrapper**: Direct capability to AutoBalancer (RebalancingHandler removed)
3. **Self-Scheduling AutoBalancers**: AutoBalancers chain their own subsequent executions
4. **Recovery-Only Supervisor**: Processes bounded pending queue, not all yield vaults

### Component Design

```
FlowYieldVaults Contract Account
    |
    +-- FlowYieldVaultsScheduler
    |       +-- SchedulerManager (tracks scheduled transactions)
    |       +-- Supervisor (recovery handler for failed schedules)
    |
    +-- FlowYieldVaultsSchedulerRegistry
    |       +-- yieldVaultRegistry: {UInt64: Bool}
    |       +-- handlerCaps: {UInt64: Capability<AutoBalancer>}
    |       +-- pendingQueue: {UInt64: Bool}  (bounded by MAX_BATCH_SIZE=50)
    |       +-- supervisorCap
    |
    +-- FlowYieldVaultsAutoBalancers
            +-- AutoBalancer (per YieldVault) implements TransactionHandler
```

### Execution Flow

1. **YieldVault Creation** (atomic):
   - User creates YieldVault via `create_yield_vault.cdc`
   - Strategy creates AutoBalancer in `_initNewAutoBalancer()`
   - `registerYieldVault()` atomically:
     - Issues capability directly to AutoBalancer
     - Registers in FlowYieldVaultsSchedulerRegistry
     - Schedules first execution
   - If any step fails, entire transaction reverts

2. **Scheduled Execution**:
   - FlowTransactionScheduler triggers at scheduled time
   - Calls `AutoBalancer.executeTransaction()`
   - AutoBalancer.rebalance() executes
   - AutoBalancer self-schedules next execution (if configured with recurringConfig)

3. **Recovery** (Supervisor):
   - Processes `getPendingYieldVaultIDs()` (MAX 50 per run)
   - Schedules yield vaults that failed to self-schedule
   - Self-reschedules if pending work remains

## Files

### Core Contracts
- **`FlowYieldVaultsScheduler.cdc`** (~730 lines)
  - SchedulerManager resource
  - Supervisor resource (recovery handler)
  - Atomic registration with initial scheduling
  
- **`FlowYieldVaultsSchedulerRegistry.cdc`** (~155 lines)
  - Registry storage (separate contract)
  - Pending queue with MAX_BATCH_SIZE pagination
  - Events: YieldVaultRegistered, YieldVaultUnregistered, YieldVaultEnqueuedPending, YieldVaultDequeuedPending

### Transactions
- `schedule_rebalancing.cdc` - Manual schedule (after canceling auto-schedule)
- `cancel_scheduled_rebalancing.cdc` - Cancel and get refund
- `setup_scheduler_manager.cdc` - Initialize SchedulerManager
- `setup_supervisor.cdc` - Initialize Supervisor
- `schedule_supervisor.cdc` - Schedule Supervisor for recovery
- `enqueue_pending_yield_vault.cdc` - Manually enqueue for recovery

### Scripts
- `get_scheduled_rebalancing.cdc` - Query specific yield vault's schedule
- `get_all_scheduled_rebalancing.cdc` - List all scheduled rebalancing
- `get_registered_yield_vault_ids.cdc` - Get registered yield vault IDs
- `get_pending_count.cdc` - Check pending queue size
- `estimate_rebalancing_cost.cdc` - Estimate fees
- `has_wrapper_cap_for_yield_vault.cdc` - Check if handler cap exists (renamed from wrapper)

### Tests
- `scheduled_supervisor_test.cdc` - Supervisor and multi-yield-vault tests
- `scheduled_rebalance_integration_test.cdc` - Integration tests
- `scheduled_rebalance_scenario_test.cdc` - Scenario-based tests
- `scheduler_edge_cases_test.cdc` - Edge case tests

## Key Features

### Automatic Scheduling at YieldVault Creation
- No manual setup required
- First rebalancing scheduled atomically with yield vault creation
- Fails safely - reverts entire transaction if scheduling fails

### Self-Scheduling AutoBalancers
- AutoBalancers with `recurringConfig` chain their own executions
- No central coordinator needed for normal operation
- Each AutoBalancer manages its own schedule independently

### Paginated Recovery (Supervisor)
- MAX_BATCH_SIZE = 50 yield vaults per Supervisor run
- Only processes pending queue (not all registered yield vaults)
- Self-reschedules if more work remains

### Events
```cadence
// FlowYieldVaultsScheduler
event RebalancingScheduled(yieldVaultID, scheduledTransactionID, timestamp, priority, isRecurring, ...)
event RebalancingCanceled(yieldVaultID, scheduledTransactionID, feesReturned)
event SupervisorSeededYieldVault(yieldVaultID, scheduledTransactionID, timestamp)

// FlowYieldVaultsSchedulerRegistry
event YieldVaultRegistered(yieldVaultID, handlerCapValid)
event YieldVaultUnregistered(yieldVaultID, wasInPendingQueue)
event YieldVaultEnqueuedPending(yieldVaultID, pendingQueueSize)
event YieldVaultDequeuedPending(yieldVaultID, pendingQueueSize)
```

## Test Coverage

| Test | Description |
|------|-------------|
| `testAutoRegisterAndSupervisor` | YieldVault creation auto-registers and schedules |
| `testMultiYieldVaultNativeScheduling` | 3 yield vaults all self-schedule natively |
| `testMultiYieldVaultIndependentExecution` | Multiple yield vaults execute independently 3+ times |
| `testPaginationStress` | 18 yield vaults (>MAX_BATCH_SIZE) all registered and execute |
| `testSupervisorDoesNotDisruptHealthyYieldVaults` | Healthy yield vaults continue executing with Supervisor running |
| `testStuckYieldVaultDetectionLogic` | Detection logic correctly identifies healthy vs stuck yield vaults |
| `testInsufficientFundsAndRecovery` | Complete failure and recovery cycle with insufficient funds |
| `testYieldVaultHasNativeScheduleAfterCreation` | Yield vault has active schedule immediately after creation |

## Security

1. **Access Control**:
   - `getSupervisorCap()` - `access(account)`
   - `getHandlerCap()` - `access(account)`
   - `enqueuePending()` - `access(account)`
   - Registration/unregistration only from FlowYieldVaultsAutoBalancers

2. **Atomic Operations**:
   - YieldVault creation + registration + scheduling is atomic
   - Failure at any step reverts the entire transaction

3. **Bounded Operations**:
   - Supervisor processes MAX 50 yield vaults per execution
   - Prevents compute limit exhaustion

## Changelog

### Version 2.0.0 (November 26, 2025)
- Removed RebalancingHandler wrapper
- Atomic initial scheduling at yield vault registration
- Paginated Supervisor with pending queue
- Self-scheduling AutoBalancers
- Moved registration to FlowYieldVaultsAutoBalancers
- Added comprehensive events

### Version 1.0.0 (November 10, 2025)
- Initial implementation
- Central Supervisor scanning all yield vaults
- RebalancingHandler wrapper

---

**Status**: Implementation complete, tests passing  
**Last Updated**: November 26, 2025

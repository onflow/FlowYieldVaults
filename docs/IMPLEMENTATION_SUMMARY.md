# Scheduled Rebalancing Implementation Summary

## Overview

Scheduled rebalancing for FlowYieldVaults is built on Flow's native transaction scheduler.
AutoBalancers schedule themselves for normal recurring execution, while
`FlowYieldVaultsSchedulerV1.Supervisor` exists only to detect and recover stuck vaults.

## Status

This document reflects the current scheduler architecture in this repository.

- Last Updated: March 10, 2026
- Current batch size: `FlowYieldVaultsSchedulerRegistry.MAX_BATCH_SIZE = 5`
- Current scheduler contract: `FlowYieldVaultsSchedulerV1.cdc`

## Architecture

### Key Design Principles

1. Atomic registration and first scheduling at YieldVault creation.
2. Direct AutoBalancer capabilities, with no scheduling wrapper layer.
3. Native self-scheduling for healthy recurring AutoBalancers.
4. Recovery-only Supervisor with bounded scanning and bounded pending-queue processing.
5. LRU stuck-scan ordering across recurring scan participants, so the longest-idle recurring vaults are checked first.

### Main Components

```text
FlowYieldVaults Account
    |
    +-- FlowYieldVaultsAutoBalancers
    |       +-- Stores account-hosted AutoBalancers
    |       +-- Issues handler/schedule capabilities
    |       +-- Sets shared execution callback
    |       +-- Starts first native schedule
    |
    +-- FlowYieldVaultsSchedulerRegistry
    |       +-- yieldVaultRegistry: {UInt64: Bool} (all live yield vault IDs)
    |       +-- handlerCaps
    |       +-- scheduleCaps
    |       +-- pendingQueue
    |       +-- listNodes / listHead / listTail (LRU recurring-only stuck-scan order)
    |       +-- supervisorCap
    |
    +-- FlowYieldVaultsSchedulerV1
            +-- Supervisor resource
            +-- scheduling cost/config helpers
```

## Execution Flow

### YieldVault Creation

1. `create_yield_vault.cdc` creates a strategy.
2. The strategy calls `FlowYieldVaultsAutoBalancers._initNewAutoBalancer(...)`.
3. `_initNewAutoBalancer(...)`:
   - stores the AutoBalancer
   - issues handler and schedule capabilities
   - registers the vault in `FlowYieldVaultsSchedulerRegistry`
   - sets a shared `RegistryReportCallback`
   - schedules the first rebalance when `recurringConfig != nil`
4. If any required step fails, the transaction reverts.

### Normal Operation

1. `FlowTransactionScheduler` executes the AutoBalancer.
2. The AutoBalancer rebalances.
3. If recurring scheduling is configured, the AutoBalancer schedules its next run.
4. The shared execution callback reports success to the registry.
5. `reportExecution()` moves that vault to the head of the LRU list (most recently executed).

### Recovery Operation

Each Supervisor run has two bounded steps:

1. Stuck detection:
   - reads up to `MAX_BATCH_SIZE` least-recently-executed recurring-participant vault IDs from `pruneAndGetStuckScanCandidates(...)`
   - checks whether each candidate is overdue and lacks an active schedule
   - enqueues stuck vaults into `pendingQueue`

2. Pending recovery:
   - reads up to `MAX_BATCH_SIZE` vault IDs from `getPendingYieldVaultIDsPaginated(page: 0, size: UInt(MAX_BATCH_SIZE))`
   - borrows each vault's `Schedule` capability
   - calls `scheduleNextRebalance(whileExecuting: nil)` directly
   - dequeues successfully recovered vaults

If the Supervisor itself is configured with a recurring interval, it self-reschedules after the run.

## Core Contracts

- `FlowYieldVaultsAutoBalancers.cdc`
  - account-hosted AutoBalancer creation and cleanup
  - handler/schedule capability issuance
  - shared execution callback wiring

- `FlowYieldVaultsSchedulerRegistry.cdc`
  - registered vault tracking
  - pending queue
  - handler/schedule capability storage
  - LRU stuck-scan ordering for recurring participants

- `FlowYieldVaultsSchedulerV1.cdc`
  - Supervisor recovery handler
  - Supervisor configuration and cost estimation helpers
  - Supervisor recovery and self-reschedule events

## Scheduler-Related Transactions

- `cadence/transactions/flow-yield-vaults/admin/schedule_supervisor.cdc`
- `cadence/transactions/flow-yield-vaults/admin/destroy_supervisor.cdc`
- `cadence/transactions/flow-yield-vaults/admin/destroy_and_reset_supervisor.cdc`
- `cadence/transactions/flow-yield-vaults/enqueue_pending_yield_vault.cdc`
- `cadence/transactions/flow-yield-vaults/admin/set_default_recurring_interval.cdc`
- `cadence/transactions/flow-yield-vaults/admin/set_default_exec_effort.cdc`
- `cadence/transactions/flow-yield-vaults/admin/set_default_min_fee_fallback.cdc`
- `cadence/transactions/flow-yield-vaults/admin/set_default_fee_margin_multiplier.cdc`
- `cadence/transactions/flow-yield-vaults/admin/set_default_priority.cdc`

## Scheduler-Related Scripts

- `cadence/scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc`
- `cadence/scripts/flow-yield-vaults/get_registered_yield_vault_count.cdc`
- `cadence/scripts/flow-yield-vaults/get_pending_count.cdc`
- `cadence/scripts/flow-yield-vaults/get_pending_yield_vaults_paginated.cdc`
- `cadence/scripts/flow-yield-vaults/get_scheduler_config.cdc`
- `cadence/scripts/flow-yield-vaults/estimate_rebalancing_cost.cdc`
- `cadence/scripts/flow-yield-vaults/has_active_schedule.cdc`
- `cadence/scripts/flow-yield-vaults/is_stuck_yield_vault.cdc`
- `cadence/scripts/flow-yield-vaults/has_wrapper_cap_for_yield_vault.cdc`
  - legacy script name; it checks for the direct handler capability stored in the registry

## Current Events

```cadence
// FlowYieldVaultsSchedulerV1
event YieldVaultRecovered(yieldVaultID: UInt64)
event YieldVaultRecoveryFailed(yieldVaultID: UInt64, error: String)
event StuckYieldVaultDetected(yieldVaultID: UInt64)
event SupervisorRescheduled(scheduledTransactionID: UInt64, timestamp: UFix64)
event SupervisorRescheduleFailed(
    timestamp: UFix64,
    requiredFee: UFix64?,
    availableBalance: UFix64?,
    error: String
)

// FlowYieldVaultsSchedulerRegistry
event YieldVaultRegistered(yieldVaultID: UInt64)
event YieldVaultUnregistered(yieldVaultID: UInt64, wasInPendingQueue: Bool)
event YieldVaultEnqueuedPending(yieldVaultID: UInt64, pendingQueueSize: Int)
event YieldVaultDequeuedPending(yieldVaultID: UInt64, pendingQueueSize: Int)
```

## Test Coverage

- `scheduled_supervisor_test.cdc`
  - native scheduling, pagination, healthy-supervisor no-op behavior, stuck detection, recovery
- `scheduled_rebalance_integration_test.cdc`
  - scheduler integration behavior
- `scheduled_rebalance_scenario_test.cdc`
  - multi-round scheduling scenarios
- `scheduler_edge_cases_test.cdc`
  - edge cases and invariants
- `yield_vault_lifecycle_test.cdc`
  - vault lifecycle with scheduler wiring
- `atomic_registration_gc_test.cdc`
  - atomic registration and cleanup behavior

## Security and Operational Notes

1. Registration, execution reporting, pending enqueue/dequeue, and unregister operations are account-restricted.
2. Supervisor processing is bounded to avoid unbounded compute growth.
3. Healthy recurring execution depends on the FlowYieldVaults account retaining sufficient FLOW for fees.
4. Recovery does not replace off-chain monitoring; it only restores schedules for vaults that are overdue and unscheduled.

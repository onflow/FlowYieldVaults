# Critical Analysis: FlowVaults Scheduler & Strategy Updates
**Date:** November 26, 2025
**Based on:** Review by sisyphusSmiling

## Executive Summary
The current branch is **not ready for merge**. It contains fundamental architectural scalability issues that will cause the `Supervisor` to run out of execution limits (gas/compute) as the number of vaults grows. Additionally, recent commits have reverted critical logic required for Mainnet 4626 integration.

The reviewer strongly suggests a pivot in architecture: moving away from a central iterating Supervisor towards **internalized recurrent scheduling** within AutoBalancers, or at minimum, a paginated queue system.

---

## 1. Critical Scalability & Architecture Issues

### A. The O(N) Supervisor Problem
**Location:** `FlowVaultsScheduler.cdc`, `FlowVaultsSchedulerRegistry.cdc`

The current implementation iterates over the entire list of registered Tide IDs to check if they need scheduling.
> *"The current setup still is guaranteed not to scale. Even with relatively modest numbers, the Supervisor will inevitably run out of compute on its scheduled runs."*

**Specific Offenders:**
1.  `FlowVaultsScheduler.cdc`: Iterating `registeredTideIDs` in the Supervisor loop.
2.  `getRegisteredTideIDs()`: Returns all keys from the dictionary. This function is unsafe for production use as it will eventually exceed memory/computation limits.

### B. Unnecessary Wrapper Complexity
**Location:** `RebalancingHandler` in `FlowVaultsScheduler.cdc`

The `RebalancingHandler` is deemed redundant. It wraps the `AutoBalancer` but adds no new data or logic.
*   **Recommendation:** Remove the wrapper entirely. The `AutoBalancer` stored in account storage should be accessed directly.

### C. The "Two Paths" Forward
The reviewer proposes two solutions to fix the scalability issue. **Path 2 appears preferred** for simplicity.

1.  **Path 1 (Queue-based):** Queue AutoBalancers by Tide ID upon creation into a "to-be-seeded" list. The Supervisor iterates over this queue in a **paginated** manner.
2.  **Path 2 (Internalized - Recommended):** Internalize the recurrent scheduling logic directly into the `AutoBalancer`.
    *   Schedule the *next* execution immediately upon creation/execution.
    *   This removes the need for the `Manager`, `Supervisor`, and `RebalancingHandler` entirely.

---

## 2. Code Logic & Integration Regressions

### A. Strategy Logic Reversion (Critical)
**Location:** `FlowVaultsStrategies.cdc` (`mUSDCStrategyComposer`)

Changes made to `mUSDCStrategyComposer` effectively undid logic required for Mainnet integration with 4626 vaults.
*   **Action:** These changes **must be undone**. The previous version (on `main`) was correct.

### B. Registration Lifecycle Placement
**Location:** `FlowVaults.cdc` vs `FlowVaultsAutoBalancers.cdc`

Currently, registration with the Scheduler happens in `FlowVaults.cdc` (the factory/manager level).
*   **Feedback:** Registration logic should live where it is most relevant—inside the AutoBalancer lifecycle methods.
*   **Action:**
    *   Move `registerTide` call to `FlowVaultsAutoBalancers._initNewAutoBalancer`.
    *   Move `unregisterTide` call to `FlowVaultsAutoBalancers._cleanupAutoBalancer`.

---

## 3. Security & Access Control

### A. Leaked Capabilities
**Location:** `FlowVaultsSchedulerRegistry.cdc`

The following methods expose capabilities publicly and need to be restricted:
*   `getSupervisorCap()`
*   `getWrapperCap(tideID: UInt64)`

**Action:** Change access level to restricted (e.g., `access(contract)` or specific entitlement) or make them view-only if possible.

### B. Supervisor Creation Visibility
**Location:** `FlowVaultsScheduler.cdc`

`createSupervisor()` is `access(account)` but listed under Public Functions.
*   **Action:** Make `access(self)` and call strictly within `init()` (or `ensureSupervisorConfigured` if lazy loading is strictly necessary, though `init` is preferred).

---

## 4. Minor Refactors & Clean Code

*   **`estimate_rebalancing_cost.cdc`**: Simplify priority assignment using `FlowTransactionScheduler.Priority(rawValue: priorityRaw)`.
*   **`FlowVaultsScheduler.cdc`**:
    *   `unregisterTide`: When borrowing `FlowToken.Vault`, remove `auth(FungibleToken.Withdraw)` if only reading/depositing is required.
    *   `getSchedulerConfig`: Review if this wrapper is actually needed.
    *   `deriveSupervisorPath`: Hardcoded string construction is brittle; verify if multiple supervisors are actually intended (likely not).

## Summary of Action Plan

1.  **Revert** `FlowVaultsStrategies.cdc` changes immediately.
2.  **Decide on Architecture:** Adopt "Path 2" (Internalized Scheduling) if possible to delete the Supervisor complexity. If retaining Supervisor, implement **Pagination** immediately.
3.  **Refactor Registration:** Move register/unregister calls into `FlowVaultsAutoBalancers` methods.
4.  **Lock Down:** Restrict access to Registry capability getters.


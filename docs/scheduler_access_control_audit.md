# FlowVaults Scheduler Access Control and Capability Audit

This document provides a comprehensive audit of all access controls and capabilities in the FlowVaults Scheduler system.

---

## 1. Contract Deployment Assumptions

Both contracts are deployed to the **same account** (FlowVaults account):
- `FlowVaultsScheduler` - Main scheduler logic
- `FlowVaultsSchedulerRegistry` - Central registry storage

This is critical because `access(account)` functions can be called across contracts deployed to the same account.

---

## 2. FlowVaultsSchedulerRegistry Access Control Audit

### Contract-Level State (all `access(self)`)

| Variable | Type | Access | Justification |
|----------|------|--------|---------------|
| `tideRegistry` | `{UInt64: Bool}` | `access(self)` | Only modifiable through contract functions |
| `wrapperCaps` | `{UInt64: Capability<...>}` | `access(self)` | Sensitive capabilities, not directly accessible |
| `supervisorCap` | `Capability<...>?` | `access(self)` | Sensitive capability, not directly accessible |

### Functions

| Function | Access | Who Can Call | Justification |
|----------|--------|--------------|---------------|
| `register(tideID, wrapperCap)` | `access(account)` | FlowVaultsScheduler contract only | Only the scheduler should register tides to prevent unauthorized capability injection |
| `unregister(tideID)` | `access(account)` | FlowVaultsScheduler contract only | Only the scheduler should unregister to ensure proper cleanup |
| `getRegisteredTideIDs()` | `access(all)` | Anyone | Read-only, returns just IDs (no sensitive data) |
| `getWrapperCap(tideID)` | `access(all)` | Anyone | Returns capability, but cap is useless without `FlowTransactionScheduler.Execute` context |
| `setSupervisorCap(cap)` | `access(account)` | FlowVaultsScheduler contract only | Only scheduler should set the global supervisor |
| `getSupervisorCap()` | `access(all)` | Anyone | Read-only, cap is useless without execution context |

### Security Notes

- **Capability Exposure Risk**: `getWrapperCap()` and `getSupervisorCap()` return capabilities publicly. However, these capabilities have `auth(FlowTransactionScheduler.Execute)` entitlement which can only be exercised by the FlowTransactionScheduler system contract during scheduled execution. An attacker cannot directly call `executeTransaction()` on these capabilities.

---

## 3. FlowVaultsScheduler Access Control Audit

### Constants (all `access(all) let`)

| Constant | Access | Justification |
|----------|--------|---------------|
| `DEFAULT_RECURRING_INTERVAL` | `access(all)` | Read-only, public configuration |
| `DEFAULT_PRIORITY` | `access(all)` | Read-only, public configuration |
| `DEFAULT_EXECUTION_EFFORT` | `access(all)` | Read-only, public configuration |
| `MIN_FEE_FALLBACK` | `access(all)` | Read-only, public configuration |
| `SchedulerManagerStoragePath` | `access(all)` | Read-only, public path |
| `SchedulerManagerPublicPath` | `access(all)` | Read-only, public path |

### Events (all `access(all)`)

All events are public - this is correct as events are meant to be observable.

### Structs (all `access(all)`)

| Struct | Access | Justification |
|--------|--------|---------------|
| `RebalancingScheduleInfo` | `access(all)` | Data struct for queries, no sensitive operations |
| `RebalancingScheduleData` | `access(all)` | Internal data struct, all fields read-only |

### Resource: RebalancingHandler

| Member | Access | Justification |
|--------|--------|---------------|
| `target` (capability) | `access(self)` | Sensitive capability to AutoBalancer, not externally accessible |
| `tideID` | `access(self)` | Internal state |
| `executeTransaction(id, data)` | `access(FlowTransactionScheduler.Execute)` | Only callable by FlowTransactionScheduler system during scheduled execution |

### Resource: SchedulerManager

| Member | Access | Justification |
|--------|--------|---------------|
| `scheduledTransactions` | `access(self)` | Internal resource map |
| `scheduleData` | `access(self)` | Internal data map |
| `scheduleRebalancing(...)` | `access(all)` | Requires valid capability; caller pays fees |
| `cancelRebalancing(tideID)` | `access(all)` | Returns funds to caller's vault; only SchedulerManager owner can call via storage |
| `getAllScheduledRebalancing()` | `access(all)` | Read-only query |
| `getScheduledRebalancing(tideID)` | `access(all)` | Read-only query |
| `getScheduledTideIDs()` | `access(all) view` | Read-only query |
| `hasScheduled(tideID)` | `access(all)` | Read-only query |
| `getScheduleData(id)` | `access(all)` | Read-only query |
| `removeScheduleData(id)` | `access(all)` | Only callable on SchedulerManager owned by caller |

**Security Note on SchedulerManager**: The `access(all)` functions on SchedulerManager are safe because:
1. SchedulerManager is a resource stored in account storage
2. Only the storage owner can borrow a reference to call these functions
3. Functions like `cancelRebalancing` return funds - harmless if called by owner
4. Functions like `scheduleRebalancing` require valid capability + fees

### Resource: Supervisor

| Member | Access | Justification |
|--------|--------|---------------|
| `managerCap` | `access(self)` | Sensitive capability to SchedulerManager |
| `feesCap` | `access(self)` | HIGHLY SENSITIVE - allows withdrawing FlowToken |
| `executeTransaction(id, data)` | `access(FlowTransactionScheduler.Execute)` | Only callable by FlowTransactionScheduler system |

**Security Note on Supervisor**: The Supervisor holds a capability to withdraw FlowTokens. This is why `createSupervisor()` is `access(account)` - only the FlowVaults account should be able to create Supervisors.

### Contract-Level Functions

| Function | Access | Who Can Call | Justification |
|----------|--------|--------------|---------------|
| `scheduleNextIfRecurring(completedID, tideID)` | `access(all)` | Anyone, but uses `self.account.storage` | Safe: requires contract account context to borrow storage |
| `createSupervisor()` | `access(account)` | FlowVaultsScheduler account only | Creates resource with sensitive capabilities |
| `ensureSupervisorConfigured()` | `access(all)` | Anyone, but uses `self.account` | Safe: all operations use `self.account` which is the contract account |
| `deriveSupervisorPath()` | `access(all)` | Anyone | Pure function, returns a path |
| `createRebalancingHandler(target, tideID)` | `access(account)` | FlowVaultsScheduler account only | Creates resource holding capability to AutoBalancer |
| `deriveRebalancingHandlerPath(tideID)` | `access(all)` | Anyone | Pure function, returns a path |
| `createSchedulerManager()` | `access(all)` | Anyone | Creates empty resource for caller's storage |
| `registerTide(tideID)` | `access(account)` | FlowVaults contract (same account) | Atomic with tide creation; issues capabilities |
| `unregisterTide(tideID)` | `access(account)` | FlowVaults contract (same account) | Atomic with tide close; cleans up resources |
| `getRegisteredTideIDs()` | `access(all)` | Anyone | Read-only delegation to registry |
| `estimateSchedulingCost(...)` | `access(all)` | Anyone | Read-only query to FlowTransactionScheduler |
| `getSchedulerConfig()` | `access(all)` | Anyone | Read-only query |

---

## 4. Capability Flow Analysis

### Capability Types Used

| Capability Type | Entitlements | Purpose |
|-----------------|--------------|---------|
| `Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>` | Execute | Allows FlowTransactionScheduler to execute scheduled transactions |
| `Capability<&FlowVaultsScheduler.SchedulerManager>` | None (read-only) | Allows Supervisor to query and schedule via manager |
| `Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>` | Withdraw | Allows Supervisor to pay fees from FlowVaults account |

### Capability Issuance Points

#### 1. In `registerTide(tideID)`

```
abCap = self.account.capabilities.storage.issue<...>(abPath)
  |
  v
RebalancingHandler(target: abCap)
  |
  v
wrapperCap = self.account.capabilities.storage.issue<...>(wrapperPath)
  |
  v
FlowVaultsSchedulerRegistry.register(tideID, wrapperCap)
```

**Security**: Only callable from FlowVaults contract due to `access(account)`.

#### 2. In `scheduleNextIfRecurring(completedID, tideID)`

Same pattern as registerTide, but only if registry cap is invalid:
```
if wrapperCap == nil || !wrapperCap!.check() {
    // Re-issue capabilities
}
```

**Security**: Uses `self.account.storage` which only works in contract account context.

#### 3. In `createSupervisor()`

```
mgrCap = self.account.capabilities.storage.issue<&SchedulerManager>(...)
feesCap = self.account.capabilities.storage.issue<auth(Withdraw) &FlowToken.Vault>(...)
  |
  v
Supervisor(managerCap: mgrCap, feesCap: feesCap)
```

**Security**: `access(account)` prevents unauthorized creation.

#### 4. In `ensureSupervisorConfigured()`

```
supCap = self.account.capabilities.storage.issue<...>(supervisorPath)
  |
  v
FlowVaultsSchedulerRegistry.setSupervisorCap(supCap)
```

**Security**: Uses `self.account` so only works for contract account.

### Capability Usage Points

| Location | Capability Used | Operation |
|----------|-----------------|-----------|
| `RebalancingHandler.executeTransaction()` | `self.target` | Borrows and calls `executeTransaction` on AutoBalancer |
| `Supervisor.executeTransaction()` | `self.managerCap` | Borrows SchedulerManager to schedule children |
| `Supervisor.executeTransaction()` | `self.feesCap` | Withdraws FlowTokens to pay for child schedules |
| `Supervisor.executeTransaction()` | `FlowVaultsSchedulerRegistry.getWrapperCap(tideID)` | Gets wrapper cap to schedule child |
| `Supervisor.executeTransaction()` | `FlowVaultsSchedulerRegistry.getSupervisorCap()` | Gets self-cap for rescheduling |
| `scheduleNextIfRecurring()` | `FlowVaultsSchedulerRegistry.getWrapperCap(tideID)` | Reuses or issues new wrapper cap |

---

## 5. Integration with FlowVaults.cdc

### Tide Creation Flow

```
FlowVaults.TideManager.createTide(...)
    |
    v
tide <- create Tide(...)
    |
    v
self.addTide(<-tide)
    |
    v
FlowVaultsScheduler.registerTide(tideID: newID)  // access(account) - same account
```

### Tide Close Flow

```
FlowVaults.TideManager.closeTide(id)
    |
    v
FlowVaultsScheduler.unregisterTide(tideID: id)  // access(account) - same account
    |
    v
tide <- self._withdrawTide(id)
    |
    v
Burner.burn(<-tide)
```

---

## 6. Security Verification Summary

### Access Control Verification

| Check | Status | Notes |
|-------|--------|-------|
| Factory functions for privileged resources restricted | PASS | `createSupervisor`, `createRebalancingHandler` are `access(account)` |
| Registry mutations restricted | PASS | `register`, `unregister`, `setSupervisorCap` are `access(account)` |
| Tide registration/unregistration restricted | PASS | `registerTide`, `unregisterTide` are `access(account)` |
| Resource internal state protected | PASS | All sensitive fields are `access(self)` |
| Public functions are safe | PASS | Read-only or require caller to own the resource |

### Capability Security Verification

| Check | Status | Notes |
|-------|--------|-------|
| Execute entitlement only usable by scheduler | PASS | `FlowTransactionScheduler.Execute` is controlled by system |
| Fee withdrawal capability protected | PASS | Only Supervisor holds it; Supervisor creation restricted |
| Capabilities not leaking sensitive entitlements | PASS | Public getters return caps but entitlements can't be exercised directly |
| Capability reuse implemented | PASS | Registry cap reused when valid |

### Garbage Collection Verification

| Check | Status | Notes |
|-------|--------|-------|
| scheduleData cleaned on cancel | PASS | `cancelRebalancing` removes entry |
| scheduleData cleaned after execution | PASS | `scheduleNextIfRecurring` removes entry |
| Wrapper resources destroyed on unregister | PASS | `unregisterTide` destroys RebalancingHandler |
| Registry entries cleaned on unregister | PASS | `unregisterTide` calls `FlowVaultsSchedulerRegistry.unregister` |

---

## 7. Potential Concerns and Mitigations

### Concern 1: Public `getWrapperCap()` Returns Capability

**Risk**: Anyone can read the wrapper capability from the registry.

**Mitigation**: The capability has `auth(FlowTransactionScheduler.Execute)` entitlement which can only be exercised by the FlowTransactionScheduler system contract. An attacker cannot call `executeTransaction()` directly on the capability.

### Concern 2: `scheduleNextIfRecurring` is `access(all)`

**Risk**: Anyone might call this function.

**Mitigation**: The function uses `self.account.storage.borrow<>()` internally. This only succeeds when executed in the context of a transaction signed by the contract account, or when called from within the contract's code execution path (e.g., from `RebalancingHandler.executeTransaction()`).

### Concern 3: Supervisor Holds Withdraw Capability

**Risk**: The Supervisor can withdraw FlowTokens from the FlowVaults account.

**Mitigation**: 
1. `createSupervisor()` is `access(account)` - only the FlowVaults account can create one
2. The Supervisor resource is stored in the FlowVaults account's storage
3. The capability is only used during scheduled execution via `FlowTransactionScheduler.Execute` entitlement

### Concern 4: Capability Accumulation

**Risk**: Multiple capabilities could be issued over time.

**Mitigation**:
1. `registerTide()` checks if valid cap exists before issuing new one
2. `scheduleNextIfRecurring()` reuses existing cap from registry
3. Caps pointing to destroyed resources become invalid (`check()` returns false)

---

## 8. Conclusion

The access control and capability model is correctly implemented:

1. **Principle of Least Privilege**: Functions are restricted to the minimum access level needed
2. **Same-Account Cross-Contract Calls**: `access(account)` correctly allows FlowVaults to call scheduler functions
3. **Capability Safety**: Sensitive capabilities are properly guarded by entitlements and storage restrictions
4. **Garbage Collection**: All resources and data are properly cleaned up on tide close
5. **Idempotency**: Registration and unregistration are idempotent and safe to call multiple times

No security issues identified in the current implementation.


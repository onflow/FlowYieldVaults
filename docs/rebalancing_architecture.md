# Rebalancing Architecture: AutoBalancer, FlowALP Position, and Scheduled Transactions

## 1. Main Components and Their Responsibilities

### FlowYieldVaults (YieldVaults)
- Owns `YieldVault` and `YieldVaultManager`
- Each YieldVault wraps a **FlowYieldVaults Strategy** (e.g. `TracerStrategy`)
- The YieldVault itself does **not** know about scheduling or FlowALP; it just holds a strategy resource

### MockStrategies (TracerStrategy stack)
  - `TracerStrategyComposer` wires together:
  - A **DeFiActions.AutoBalancer** (manages Yield token exposure around deposits value)
  - A **FlowALP.Position** (borrow/lend position in the FlowALP pool)
  - Swappers and connectors that shuttle value between AutoBalancer and FlowALP
- This is where the **YieldVault -> AutoBalancer -> FlowALP** wiring is defined

### FlowYieldVaultsAutoBalancers
  - Utility contract for:
  - Storing AutoBalancer resources in the FlowYieldVaults account (per YieldVault/UniqueID)
  - Publishing public/private capabilities
  - Setting the AutoBalancer's **self capability** (for scheduling)
  - **Registering/unregistering with FlowYieldVaultsSchedulerRegistry**
- On `_initNewAutoBalancer()`: registers yield vault and schedules first execution atomically
- On `_cleanupAutoBalancer()`: unregisters the vault, deletes AutoBalancer capability controllers, and burns the AutoBalancer

### DeFiActions.AutoBalancer (from FlowActions)
- Holds a vault of some asset (here: `YieldToken`)
  - Tracks:
  - `valueOfDeposits` (historical value of all deposits)
  - `currentValue` (vault balance * oracle price)
  - `rebalanceRange` / thresholds
  - Provides:
  - `rebalance(force: Bool)`: adjusts position based on price/value changes
  - `executeTransaction(id, data)`: entrypoint for **FlowTransactionScheduler**
  - `scheduleNextRebalance()`: self-schedules next execution (when configured with recurringConfig)

### FlowALP.Pool + Position
- Maintains positions, collateral, MOET debt, health
- Key function: `rebalancePosition(pid: UInt64, force: Bool)`:
  - If undercollateralized and there is a `topUpSource`, pulls extra collateral
  - If overcollateralized and there is a `drawDownSink`, withdraws collateral

### FlowYieldVaultsSchedulerV1 + FlowYieldVaultsSchedulerRegistry
- **FlowYieldVaultsSchedulerRegistry** stores:
  - `yieldVaultRegistry`: all live yield vault IDs known to scheduler infrastructure
  - `handlerCaps`: direct capabilities to AutoBalancers (no wrapper)
  - `pendingQueue`: yield vaults needing (re)seeding; processing is bounded by `MAX_BATCH_SIZE = 5` per Supervisor run
  - `stuckScanOrder`: LRU-ordered recurring-only subset used for stuck detection; recurring vaults call `reportExecution()` on each run to move themselves to the most-recently-executed end, so the Supervisor scans the longest-idle recurring vaults first
  - `supervisorCap`: capability for Supervisor self-scheduling
- **FlowYieldVaultsSchedulerV1** provides:
  - `Supervisor`: recovery handler for failed schedules
  - Scheduling cost estimation and Supervisor configuration helpers

---

## 2. How the Tracer Strategy Wires AutoBalancer and FlowALP Together

Inside `MockStrategies.TracerStrategyComposer.createStrategy(...)`:

### Step 1: Create an AutoBalancer
   - Configured with:
  - Oracle: `MockOracle.PriceOracle()`
  - Vault type: `YieldToken.Vault`
  - Thresholds: `lowerThreshold = 0.95`, `upperThreshold = 1.05`
  - Recurring config: non-`nil` (enables native AutoBalancer self-scheduling)
   - Saved via `FlowYieldVaultsAutoBalancers._initNewAutoBalancer(...)`, which:
  - Stores the AutoBalancer
  - Issues public capability
  - Issues a **self-cap** with `auth(FungibleToken.Withdraw, FlowTransactionScheduler.Execute)`
  - **Registers with scheduler and schedules first execution atomically**

### Step 2: Wire Stable <-> Yield around the AutoBalancer
- Create `abaSink` and `abaSource` around the AutoBalancer
- Attach swappers (MockSwapper or UniswapV3) for MOET <-> Yield
- Direct MOET -> Yield into `abaSink`, Yield -> MOET from `abaSource`

### Step 3: Open a FlowALP position
- Call `poolRef.createPosition(funds, issuanceSink: abaSwapSink, repaymentSource: abaSwapSource, pushToDrawDownSink: true)`
- Initial user Flow goes through `abaSwapSink` to become Yield, deposited into AutoBalancer, then into FlowALP position

### Step 4: Create FlowALP position-level sink/source
   - `positionSink = position.createSinkWithOptions(type: collateralType, pushToDrawDownSink: true)`  
   - `positionSource = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)`

### Step 5: Wire AutoBalancer's rebalance sink into FlowALP position
- Create `positionSwapSink` to swap Yield -> Flow and deposit into `positionSink`
- Call `autoBalancer.setSink(positionSwapSink, updateSinkID: true)`
- When AutoBalancer rebalances, it withdraws Yield, swaps to Flow, deposits into FlowALP position

### Step 6: FlowALP's `pushToDrawDownSink` triggers position rebalancing
- In FlowALP's `depositAndPush` logic with `pushToDrawDownSink: true`:
     ```cadence
     if pushToDrawDownSink {
         self.rebalancePosition(pid: pid, force: true)
     }
     ```
- Any deposit via that sink automatically triggers `rebalancePosition(pid, force: true)`

**Conclusion:** When AutoBalancer performs a rebalance that moves value through its sink, it indirectly causes:
- An update in the FlowALP position via deposits/withdrawals
- A call to `FlowALP.Pool.rebalancePosition(pid, force: true)`

---

## 3. Scheduled Rebalancing Architecture

### No Wrapper - Direct AutoBalancer Capability

The capability is issued directly to the AutoBalancer at its storage path:

   ```cadence
// In _initNewAutoBalancer():
let abPath = FlowYieldVaultsAutoBalancers.deriveAutoBalancerPath(id: yieldVaultID, storage: true) as! StoragePath
let handlerCap = self.account.capabilities.storage
    .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(abPath)
```

### Atomic Registration at YieldVault Creation

When `_initNewAutoBalancer()` is called:

   ```cadence
// Register with the registry and schedule first execution atomically
// This panics if scheduling fails, reverting AutoBalancer creation
FlowYieldVaultsSchedulerRegistry.register(
    yieldVaultID: uniqueID.id,
    handlerCap: handlerCap,
    scheduleCap: scheduleCap,
    participatesInStuckScan: recurringConfig != nil
)
autoBalancerRef.scheduleNextRebalance(whileExecuting: nil)
```

`_initNewAutoBalancer()` atomically:
1. Issues capabilities to the AutoBalancer
2. Registers the vault in `FlowYieldVaultsSchedulerRegistry`
3. Sets the shared execution callback used to report successful runs
4. Schedules the first execution directly on the AutoBalancer
5. If any step fails, the entire transaction reverts

### Self-Scheduling AutoBalancers

After each execution, AutoBalancers with `recurringConfig` call `scheduleNextRebalance()`:

   ```cadence
access(FlowTransactionScheduler.Execute)
fun executeTransaction(id: UInt64, data: AnyStruct?) {
    // Extract force parameter
    let force = (data as? {String: AnyStruct})?["force"] as? Bool ?? false
    
    // Execute rebalance
    self.rebalance(force: force)
    
    // Self-schedule next execution if configured
    if let config = self.recurringConfig {
        self.scheduleNextRebalance()
       }
   }
   ```

### Supervisor Recovery (Bounded)

The Supervisor runs two steps per execution:

**Step 1 – Stuck detection** (when `scanForStuck == true`):
Fetches up to `MAX_BATCH_SIZE` candidates from `getStuckScanCandidates(limit:)`, which returns recurring scan participants starting from the least-recently-executed tail of `stuckScanOrder`. Vaults that are stuck (recurring config set, no active schedule, overdue) are enqueued into `pendingQueue`.

**Step 2 – Pending processing**:
Seeds vaults from `pendingQueue` (up to `MAX_BATCH_SIZE` per run via `getPendingYieldVaultIDsPaginated(page: 0, size: UInt(MAX_BATCH_SIZE))`).

  ```cadence
access(FlowTransactionScheduler.Execute)
fun executeTransaction(id: UInt64, data: AnyStruct?) {
    // STEP 1: scan least-recently-executed recurring participants for stuck detection
    let candidates = FlowYieldVaultsSchedulerRegistry.getStuckScanCandidates(
        limit: UInt(FlowYieldVaultsSchedulerRegistry.MAX_BATCH_SIZE))
    for yieldVaultID in candidates {
        if FlowYieldVaultsAutoBalancers.isStuckYieldVault(id: yieldVaultID) {
            FlowYieldVaultsSchedulerRegistry.enqueuePending(yieldVaultID: yieldVaultID)
        }
    }

    // STEP 2: process pending queue (MAX_BATCH_SIZE per run)
    let pendingYieldVaults = FlowYieldVaultsSchedulerRegistry.getPendingYieldVaultIDsPaginated(
        page: 0,
        size: UInt(FlowYieldVaultsSchedulerRegistry.MAX_BATCH_SIZE)
    )
    for yieldVaultID in pendingYieldVaults {
        // ... schedule via scheduleCap, dequeue ...
    }

    // Self-reschedule if recurringInterval was provided
    if recurringInterval != nil {
        // Schedule next Supervisor run
    }
}
  ```

Each AutoBalancer sets a shared `RegistryReportCallback` capability at creation time. On every execution, recurring scan participants call `FlowYieldVaultsSchedulerRegistry.reportExecution(yieldVaultID:)`, which moves the vault to the head of `stuckScanOrder` so the least-recently-executed recurring tail remains the next stuck-scan priority.

---

## 4. Behavior in Different Price Scenarios

### Only Flow collateral price changes (Yield price constant)
- FlowALP position's **health** changes (Flow is collateral)
- AutoBalancer's asset (YieldToken) oracle price unchanged
- `currentValue == valueOfDeposits` -> `valueDiff == 0` -> **rebalance is no-op**
- **Only `rebalancePosition` (FlowALP) will actually move collateral**

### Only Yield token price changes (Flow price constant)
- AutoBalancer's `currentValue` changes versus `valueOfDeposits`
- If difference exceeds threshold (or `force == true`):
  - AutoBalancer rebalances via sink (`positionSwapSink`)
  - Yield -> Flow deposited into FlowALP position with `pushToDrawDownSink == true`
  - Triggers `FlowALP.Pool.rebalancePosition(pid, force: true)`
- **Both AutoBalancer and FlowALP position are adjusted**

### Both Flow and Yield move
- If Yield changes enough, AutoBalancer rebalances
- FlowALP position's health also changes from Flow's move
- AutoBalancer-induced deposit triggers `rebalancePosition(pid, force: true)`
- **Scheduled executions become effective when Yield-side value moves**

---

## 5. Key Points

1. **Scheduled execution = calling `AutoBalancer.rebalance(force)` at time T**
   - Semantically equivalent to manual `rebalanceYieldVault`
   
2. **`rebalanceYieldVault` does NOT directly call `rebalancePosition`**
   - Position rebalancing happens **indirectly** via connector graph and FlowALP's `pushToDrawDownSink` logic
   
3. **Flow-only price changes do NOT trigger AutoBalancer rebalance**
   - AutoBalancer's `valueDiff` only sensitive to Yield side
   - Scheduled executions won't touch FlowALP position in this case
   
4. **For FlowALP position rebalancing on collateral moves**
   - Would need separate scheduling in FlowALP
   - Belongs in FlowALP/FlowActions, not FlowYieldVaults

---

## 6. Summary

| Component | Responsibility |
|-----------|---------------|
| FlowYieldVaults YieldVault | Holds strategy, user-facing |
| TracerStrategy | Wires AutoBalancer <-> FlowALP |
| AutoBalancer | Manages Yield exposure, executes rebalance |
| FlowALP Position | Manages collateral/debt health |
| FlowYieldVaultsSchedulerV1 | Supervisor recovery, fee estimation, configuration |
| FlowYieldVaultsSchedulerRegistry | Stores registry, pending queue, stuck-scan order |
| Supervisor | Stuck detection (LRU scan) + pending queue recovery (bounded) |

**Last Updated**: March 9, 2026

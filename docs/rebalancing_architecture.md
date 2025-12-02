# Rebalancing Architecture: AutoBalancer, FlowCreditMarket Position, and Scheduled Transactions

## 1. Main Components and Their Responsibilities

### FlowVaults (YieldVaults)
- Owns `YieldVault` and `YieldVaultManager`
- Each YieldVault wraps a **FlowVaults Strategy** (e.g. `TracerStrategy`)
- The YieldVault itself does **not** know about scheduling or FlowCreditMarket; it just holds a strategy resource

### FlowVaultsStrategies (TracerStrategy stack)
  - `TracerStrategyComposer` wires together:
  - A **DeFiActions.AutoBalancer** (manages Yield token exposure around deposits value)
  - A **FlowCreditMarket.Position** (borrow/lend position in the FlowCreditMarket pool)
  - Swappers and connectors that shuttle value between AutoBalancer and FlowCreditMarket
- This is where the **YieldVault -> AutoBalancer -> FlowCreditMarket** wiring is defined

### FlowVaultsAutoBalancers
  - Utility contract for:
  - Storing AutoBalancer resources in the FlowVaults account (per YieldVault/UniqueID)
  - Publishing public/private capabilities
  - Setting the AutoBalancer's **self capability** (for scheduling)
  - **Registering/unregistering with FlowVaultsScheduler**
- On `_initNewAutoBalancer()`: registers yield vault and schedules first execution atomically
- On `_cleanupAutoBalancer()`: unregisters and cancels pending schedules

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

### FlowCreditMarket.Pool + Position
- Maintains positions, collateral, MOET debt, health
- Key function: `rebalancePosition(pid: UInt64, force: Bool)`:
  - If undercollateralized and there is a `topUpSource`, pulls extra collateral
  - If overcollateralized and there is a `drawDownSink`, withdraws collateral

### FlowVaultsScheduler + FlowVaultsSchedulerRegistry
- **FlowVaultsSchedulerRegistry** stores:
  - `yieldVaultRegistry`: registered yield vault IDs
  - `handlerCaps`: direct capabilities to AutoBalancers (no wrapper)
  - `pendingQueue`: yield vaults needing (re)seeding (bounded by MAX_BATCH_SIZE=50)
  - `supervisorCap`: capability for Supervisor self-scheduling
- **FlowVaultsScheduler** provides:
  - `registerYieldVault()`: atomic registration + initial scheduling
  - `unregisterYieldVault()`: cleanup and fee refund
  - `SchedulerManager`: tracks scheduled transactions
  - `Supervisor`: recovery handler for failed schedules

---

## 2. How the Tracer Strategy Wires AutoBalancer and FlowCreditMarket Together

Inside `FlowVaultsStrategies.TracerStrategyComposer.createStrategy(...)`:

### Step 1: Create an AutoBalancer
   - Configured with:
  - Oracle: `MockOracle.PriceOracle()`
  - Vault type: `YieldToken.Vault`
  - Thresholds: `lowerThreshold = 0.95`, `upperThreshold = 1.05`
  - Recurring config: `nil` (scheduling handled by FlowVaultsScheduler)
   - Saved via `FlowVaultsAutoBalancers._initNewAutoBalancer(...)`, which:
  - Stores the AutoBalancer
  - Issues public capability
  - Issues a **self-cap** with `auth(FungibleToken.Withdraw, FlowTransactionScheduler.Execute)`
  - **Registers with scheduler and schedules first execution atomically**

### Step 2: Wire Stable <-> Yield around the AutoBalancer
- Create `abaSink` and `abaSource` around the AutoBalancer
- Attach swappers (MockSwapper or UniswapV3) for MOET <-> Yield
- Direct MOET -> Yield into `abaSink`, Yield -> MOET from `abaSource`

### Step 3: Open a FlowCreditMarket position
- Call `poolRef.createPosition(funds, issuanceSink: abaSwapSink, repaymentSource: abaSwapSource, pushToDrawDownSink: true)`
- Initial user Flow goes through `abaSwapSink` to become Yield, deposited into AutoBalancer, then into FlowCreditMarket position

### Step 4: Create FlowCreditMarket position-level sink/source
   - `positionSink = position.createSinkWithOptions(type: collateralType, pushToDrawDownSink: true)`  
   - `positionSource = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)`

### Step 5: Wire AutoBalancer's rebalance sink into FlowCreditMarket position
- Create `positionSwapSink` to swap Yield -> Flow and deposit into `positionSink`
- Call `autoBalancer.setSink(positionSwapSink, updateSinkID: true)`
- When AutoBalancer rebalances, it withdraws Yield, swaps to Flow, deposits into FlowCreditMarket position

### Step 6: FlowCreditMarket's `pushToDrawDownSink` triggers position rebalancing
- In FlowCreditMarket's `depositAndPush` logic with `pushToDrawDownSink: true`:
     ```cadence
     if pushToDrawDownSink {
         self.rebalancePosition(pid: pid, force: true)
     }
     ```
- Any deposit via that sink automatically triggers `rebalancePosition(pid, force: true)`

**Conclusion:** When AutoBalancer performs a rebalance that moves value through its sink, it indirectly causes:
- An update in the FlowCreditMarket position via deposits/withdrawals
- A call to `FlowCreditMarket.Pool.rebalancePosition(pid, force: true)`

---

## 3. Scheduled Rebalancing Architecture

### No Wrapper - Direct AutoBalancer Capability

The capability is issued directly to the AutoBalancer at its storage path:

   ```cadence
// In registerYieldVault():
let abPath = FlowVaultsAutoBalancers.deriveAutoBalancerPath(id: yieldVaultID, storage: true) as! StoragePath
let handlerCap = self.account.capabilities.storage
    .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(abPath)
```

### Atomic Registration at YieldVault Creation

When `_initNewAutoBalancer()` is called:

   ```cadence
// Register with scheduler and schedule first execution atomically
// This panics if scheduling fails, reverting AutoBalancer creation
FlowVaultsScheduler.registerYieldVault(yieldVaultID: uniqueID.id)
```

`registerYieldVault()` atomically:
1. Issues capability to AutoBalancer
2. Registers in FlowVaultsSchedulerRegistry
3. Schedules first execution via SchedulerManager
4. If any step fails, entire transaction reverts

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

The Supervisor handles failed schedules via a bounded pending queue:

  ```cadence
access(FlowTransactionScheduler.Execute)
fun executeTransaction(id: UInt64, data: AnyStruct?) {
    // Process only pending yield vaults (MAX 50 per run)
    let pendingYieldVaultIDs = FlowVaultsSchedulerRegistry.getPendingYieldVaultIDs()
    
    for yieldVaultID in pendingYieldVaults {
        if manager.hasScheduled(yieldVaultID: yieldVaultID) {
            FlowVaultsSchedulerRegistry.dequeuePending(yieldVaultID: yieldVaultID)
            continue
        }
        
        // Schedule and dequeue
        let handlerCap = FlowVaultsSchedulerRegistry.getHandlerCap(yieldVaultID: yieldVaultID)
        // ... estimate fees, schedule, dequeue ...
    }
    
    // Self-reschedule if more pending work
    if FlowVaultsSchedulerRegistry.getPendingCount() > 0 {
        // Schedule next Supervisor run
      }
  }
  ```

---

## 4. Behavior in Different Price Scenarios

### Only Flow collateral price changes (Yield price constant)
- FlowCreditMarket position's **health** changes (Flow is collateral)
- AutoBalancer's asset (YieldToken) oracle price unchanged
- `currentValue == valueOfDeposits` -> `valueDiff == 0` -> **rebalance is no-op**
- **Only `rebalancePosition` (FlowCreditMarket) will actually move collateral**

### Only Yield token price changes (Flow price constant)
- AutoBalancer's `currentValue` changes versus `valueOfDeposits`
- If difference exceeds threshold (or `force == true`):
  - AutoBalancer rebalances via sink (`positionSwapSink`)
  - Yield -> Flow deposited into FlowCreditMarket position with `pushToDrawDownSink == true`
  - Triggers `FlowCreditMarket.Pool.rebalancePosition(pid, force: true)`
- **Both AutoBalancer and FlowCreditMarket position are adjusted**

### Both Flow and Yield move
- If Yield changes enough, AutoBalancer rebalances
- FlowCreditMarket position's health also changes from Flow's move
- AutoBalancer-induced deposit triggers `rebalancePosition(pid, force: true)`
- **Scheduled executions become effective when Yield-side value moves**

---

## 5. Key Points

1. **Scheduled execution = calling `AutoBalancer.rebalance(force)` at time T**
   - Semantically equivalent to manual `rebalanceYieldVault`
   
2. **`rebalanceYieldVault` does NOT directly call `rebalancePosition`**
   - Position rebalancing happens **indirectly** via connector graph and FlowCreditMarket's `pushToDrawDownSink` logic
   
3. **Flow-only price changes do NOT trigger AutoBalancer rebalance**
   - AutoBalancer's `valueDiff` only sensitive to Yield side
   - Scheduled executions won't touch FlowCreditMarket position in this case
   
4. **For FlowCreditMarket position rebalancing on collateral moves**
   - Would need separate scheduling in FlowCreditMarket
   - Belongs in FlowCreditMarket/FlowActions, not FlowVaults

---

## 6. Summary

| Component | Responsibility |
|-----------|---------------|
| FlowVaults YieldVault | Holds strategy, user-facing |
| TracerStrategy | Wires AutoBalancer <-> FlowCreditMarket |
| AutoBalancer | Manages Yield exposure, executes rebalance |
| FlowCreditMarket Position | Manages collateral/debt health |
| FlowVaultsScheduler | Registration, atomic initial scheduling |
| FlowVaultsSchedulerRegistry | Stores registry, pending queue |
| Supervisor | Recovery for failed schedules (bounded) |

**Last Updated**: November 26, 2025

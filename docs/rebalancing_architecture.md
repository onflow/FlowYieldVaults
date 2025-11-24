## Rebalancing Architecture: AutoBalancer, FlowALP Position, and Scheduled Transactions



### 1. Main Components and Their Responsibilities



- **FlowVaults (Tides)**  
  - Owns `Tide` and `TideManager`.  
  - Each Tide wraps a **FlowVaults Strategy** (e.g. `TracerStrategy`).  
  - The Tide itself does **not** know about scheduling or FlowALP; it just holds a strategy resource.



- **FlowVaultsStrategies (TracerStrategy stack)**  
  - `TracerStrategyComposer` wires together:
    - A **DeFiActions.AutoBalancer** (manages Yield token exposure around deposits value).
    - A **FlowALP.Position** (borrow/lend position in the FlowALP pool).
    - Swappers and connectors that shuttle value between AutoBalancer and FlowALP.
  - This is where the **Tide → AutoBalancer → FlowALP** wiring is defined.



- **FlowVaultsAutoBalancers**  
  - Utility contract for:
    - Storing AutoBalancer resources in the FlowVaults account (per Tide/UniqueID).
    - Publishing public/private capabilities.
    - Setting the AutoBalancer's **self capability** (so it can be scheduled by FlowTransactionScheduler).
  - Importantly, it calls `DeFiActions.createAutoBalancer` and later sets `setSelfCapability(...)`, which also enables the AutoBalancer to implement `FlowTransactionScheduler.TransactionHandler`.



- **DeFiActions.AutoBalancer** (from FlowActions)  
  - Holds a vault of some asset (here: `YieldToken`).  
  - Tracks:
    - `valueOfDeposits` (historical value of all deposits).  
    - `currentValue` (vault balance * oracle price).  
    - `rebalanceRange` / thresholds.  
  - Provides:
    - `rebalance(force: Bool)`: adjusts position based on price/value changes.
    - `executeTransaction(id, data)`: entrypoint for **FlowTransactionScheduler**.
    - Optional **internal recurring scheduling** (when it manages its own scheduled jobs).



- **FlowALP.Pool + Position**  
  - Maintains positions, collateral, MOET debt, health.  
  - Key function: `rebalancePosition(pid: UInt64, force: Bool)`, which:
    - If undercollateralized and there is a `topUpSource`, pulls extra collateral to improve health.
    - If overcollateralized and there is a `drawDownSink`, withdraws collateral and pushes to the sink.



- **FlowVaultsScheduler + FlowVaultsSchedulerRegistry**  
  - External scheduler for **Tides**, not for generic AutoBalancers.
  - Uses **FlowTransactionScheduler** to schedule **wrapper handlers** (`RebalancingHandler`) that ultimately call the AutoBalancer.
  - `Supervisor` periodically scans registered Tides and seeds schedules for each.



---



### 2. How the Tracer Strategy Wires AutoBalancer and FlowALP Together



Inside `FlowVaultsStrategies.TracerStrategyComposer.createStrategy(...)`, the wiring is:



1. **Create an AutoBalancer**

   - Configured with:
     - Oracle: `MockOracle.PriceOracle()`.
     - Vault type: `YieldToken.Vault`.
     - Thresholds: `lowerThreshold = 0.95`, `upperThreshold = 1.05`.
     - Recurring config: `nil` (we are **not** using the AutoBalancer's own internal recurrence here).
   - Saved via `FlowVaultsAutoBalancers._initNewAutoBalancer(...)`, which:
     - Stores the AutoBalancer.
     - Issues public capability.
     - Issues a **self-cap** with `auth(FungibleToken.Withdraw, FlowTransactionScheduler.Execute)` and sets it on the AutoBalancer via `setSelfCapability`.



2. **Wire Stable ↔ Yield around the AutoBalancer**

   - Create `abaSink` and `abaSource` around the AutoBalancer (via `createBalancerSink` / `createBalancerSource`).
   - Attach swappers (e.g., `MockSwapper` or `UniswapV3SwapConnectors`) to swap MOET ↔ Yield, and direct:
     - MOET → Yield into `abaSink`.
     - Yield → MOET from `abaSource`.



3. **Open a FlowALP position using the AutoBalancer as part of the deposit pipeline**

   - Call `poolRef.createPosition(funds: <-withFunds, issuanceSink: abaSwapSink, repaymentSource: abaSwapSource, pushToDrawDownSink: true)`.
   - This means:
     - Initial user Flow goes through `abaSwapSink` to become Yield and is deposited into the AutoBalancer, then into the FlowALP position.
     - The FlowALP position is opened with the AutoBalancer integrated into its funding path.



4. **Create a FlowALP position-level sink/source**

   - `positionSink = position.createSinkWithOptions(type: collateralType, pushToDrawDownSink: true)`  
   - `positionSource = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)`



5. **Wire AutoBalancer's rebalance sink into the FlowALP position**

   - Create `positionSwapSink` to swap Yield → Flow and then deposit into `positionSink`.
   - Call:

     ```cadence
     autoBalancer.setSink(positionSwapSink, updateSinkID: true)
     ```

   - This means:
     - When the **AutoBalancer decides to rebalance** due to a value difference, it will:
       - Withdraw Yield from its vault.
       - Swap to Flow.
       - Deposit that Flow into the FlowALP position via `positionSink`.



6. **Critical FlowALP behavior: `pushToDrawDownSink` triggers position rebalancing**

   - In FlowALP's `depositAndPush` logic, when `pushToDrawDownSink` is true:

     ```cadence
     if pushToDrawDownSink {
         self.rebalancePosition(pid: pid, force: true)
     }
     ```

   - So **any deposit into the position via that sink** will automatically cause `rebalancePosition(pid, force: true)` to run.



**Conclusion:**  
Whenever AutoBalancer performs a **real rebalance that moves value through its rebalance sink**, it indirectly causes:

- An update in the FlowALP position via deposits/withdrawals, and  
- A call to `FlowALP.Pool.rebalancePosition(pid, force: true)` as part of that flow.



---



### 3. Manual Rebalancing Entry Points in Tests



There are two important manual entrypoints used heavily in tests:



1. **`rebalanceTide` helper**

   In `cadence/tests/test_helpers.cdc`:

   ```cadence
   access(all)
   fun rebalanceTide(signer: Test.TestAccount, id: UInt64, force: Bool, beFailed: Bool) {
       let res = _executeTransaction(
           "../transactions/flow-vaults/admin/rebalance_auto_balancer_by_id.cdc",
           [id, force],
           signer
       )
       Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
   }
   ```

   And in the transaction:

   ```cadence
   transaction(id: UInt64, force: Bool) {
       let autoBalancer: auth(DeFiActions.Auto) &DeFiActions.AutoBalancer

       prepare(signer: auth(BorrowValue) &Account) {
           let storagePath = FlowVaultsAutoBalancers.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
           self.autoBalancer = signer.storage.borrow<auth(DeFiActions.Auto) &DeFiActions.AutoBalancer>(from: storagePath)
               ?? panic("Could not borrow reference to AutoBalancer id \(id) at path \(storagePath)")
       }

       execute {
           self.autoBalancer.rebalance(force: force)
       }
   }
   ```

   So **`rebalanceTide` = "call `AutoBalancer.rebalance(force)` once"**, from the FlowVaults account.



2. **`rebalancePosition` helper**

   In `cadence/tests/test_helpers.cdc`:

   ```cadence
   access(all)
   fun rebalancePosition(signer: Test.TestAccount, pid: UInt64, force: Bool, beFailed: Bool) {
       let rebalanceRes = _executeTransaction(
           "../transactions/flow-alp/pool-management/rebalance_position.cdc",
           [ pid, force ],
           signer
       )
       ...
   }
   ```

   And the underlying transaction:

   ```cadence
   transaction(pid: UInt64, force: Bool) {
       prepare(signer: auth(FlowALP.EPosition) &Account) { ... }
       execute {
           self.pool.rebalancePosition(pid: pid, force: force)
       }
   }
   ```

   So **`rebalancePosition` = "call `FlowALP.Pool.rebalancePosition(pid, force)` once"**, from the protocol/FlowALP account.



---



### 4. AutoBalancer's Internal Logic: When Does It Actually Rebalance?



Key logic inside the AutoBalancer (simplified):

- It tracks:
  - `valueOfDeposits` (historic baseline).  
  - `currentValue` (vaultBalance * price).  
- On `rebalance(force)` it does roughly:

  ```cadence
  let currentPrice = oracle.price(ofToken: vaultType)
  let currentValue = self.currentValue()!
  var valueDiff = abs(currentValue - self._valueOfDeposits)

  let isDeficit = currentValue < self._valueOfDeposits
  let threshold = isDeficit
      ? (1.0 - lowerThreshold)   // deficit threshold
      : (upperThreshold - 1.0)   // surplus threshold

  if currentPrice == 0.0
     || valueDiff == 0.0
     || ((valueDiff / self._valueOfDeposits) < threshold && !force) {
      return  // no-op
  }

  // if deficit and rebalanceSource != nil, pull more
  // if surplus and rebalanceSink != nil, push surplus out
  // emit Rebalanced event if executed
  ```

- **Key consequences:**
  - If **nothing has changed** in the AutoBalancer's asset side (Yield price flat, no deposits or withdrawals), then:
    - `currentValue == valueOfDeposits` → `valueDiff == 0` → **rebalance is an immediate no-op**.
  - If there **is** a change (e.g. Yield price movement, yield accrual, etc.), and it passes threshold (or `force == true`), then:
    - On deficit: pull extra funds via `_rebalanceSource`.
    - On surplus: send excess via `_rebalanceSink`.

Because in our strategy:

- `_rebalanceSink` is `positionSwapSink` → Yield→Flow deposit into FlowALP position with `pushToDrawDownSink: true`.
- `_rebalanceSource` is `nil` for now (no top-up source from FlowALP back to AutoBalancer in this tracer bullet configuration).

So **only surplus flows from the AutoBalancer into the FlowALP position** are used to recollateralize, via sink.



---



### 5. Scheduled Rebalancing Architecture (FlowVaultsScheduler)



#### 5.1 The Wrapper Handler (`RebalancingHandler`)

- FlowVaultsScheduler defines a wrapper:

  ```cadence
  resource RebalancingHandler: FlowTransactionScheduler.TransactionHandler {
      let target: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
      let tideID: UInt64

      fun executeTransaction(id: UInt64, data: AnyStruct?) {
          let ref = self.target.borrow() ?? panic(...)
          ref.executeTransaction(id: id, data: data)    // delegates to AutoBalancer.executeTransaction
          FlowVaultsScheduler.scheduleNextIfRecurring(completedID: id, tideID: self.tideID)
          emit RebalancingExecuted(...)
      }
  }
  ```

- **`target` is a capability to the AutoBalancer handler**, obtained via FlowVaultsAutoBalancers' self capability.



#### 5.2 What happens on scheduled execution

When FlowTransactionScheduler triggers the scheduled transaction:

1. It calls `RebalancingHandler.executeTransaction(id, data)`.
2. That calls `target.executeTransaction(id, data)` on the AutoBalancer.
3. Inside the AutoBalancer:

   ```cadence
   fun executeTransaction(id, data) {
       let force = extract "force" from data or recurring config
       self.rebalance(force: force)   // same rebalance as manual
       ...
   }
   ```

4. If `rebalance(force)` is a **no-op** (e.g. `valueDiff == 0`), **nothing else happens** except maybe scheduler bookkeeping.
5. If it **does** rebalance:
   - It pushes/pulls through the sink/source.
   - If it pushes through its rebalance sink (our `positionSwapSink`), the FlowALP deposit path runs.
   - Because `pushToDrawDownSink: true` on that sink, FlowALP calls `rebalancePosition(pid, force: true)` internally.

Thus:

- A scheduled run is semantically **equivalent to calling `rebalanceTide` at that time with the same `force` flag**, and then:
  - If AutoBalancer sees real value diff → both AutoBalancer and FlowALP position are updated.
  - If not → no effective change.



#### 5.3 Supervisor and Registry

- **FlowVaultsSchedulerRegistry** stores:
  - For each Tide ID:
    - The wrapper capability (`RebalancingHandler`) reference.
  - A global Supervisor capability.

- **Supervisor** is a `TransactionHandler` that:
  - On each execution:
    - Scans all registered Tide IDs.
    - For each with **no scheduled child**:
      - Gets the stored `RebalancingHandler` capability for that tide.
      - Estimates fee and schedules a child rebalancing job via `SchedulerManager.scheduleRebalancing`.
    - Optionally, reschedules itself for recurring operation.

- The protocol flow is:

  - When a Tide is created:
    - `FlowVaults.TideManager.createTide` calls `FlowVaultsScheduler.registerTide(tideID)` to:
      - Ensure a `RebalancingHandler` exists for that Tide.
      - Register its capability in the registry.

  - When Supervisor runs:
    - It seeds a scheduled job for each registered Tide.

  - When a child fires:
    - `RebalancingHandler` invokes AutoBalancer's handler → `rebalance(force)`.

  - If configured as recurring:
    - `scheduleNextIfRecurring` schedules the next child using the same wrapper and a new timestamp.



---



### 6. Behavior in Different Price Scenarios



#### 6.1 Only Flow collateral price changes (Yield price constant)

- FlowALP position's **health** changes (since Flow is collateral).
- AutoBalancer's asset is **YieldToken**:
  - Its oracle price remains the same.
  - Its `currentValue` and `valueOfDeposits` remain equal.
- Therefore:
  - `valueDiff == 0.0` in AutoBalancer → `rebalance(force)` is a no-op.
  - Manual `rebalanceTide` call: no actual rebalance.
  - Scheduled child: exactly the same, no change.
- **Only `rebalancePosition` (FlowALP) will actually move collateral / debt in this scenario.**



#### 6.2 Only Yield token price changes (Flow price constant)

- AutoBalancer's `currentValue` changes versus its `valueOfDeposits`.
- If the difference exceeds threshold (or `force == true` and non-zero):
  - AutoBalancer rebalances, i.e., uses its sink (`positionSwapSink`) to move Yield → Flow.
  - Those Flow tokens are deposited into the FlowALP position with `pushToDrawDownSink == true`, which:
    - Calls `FlowALP.Pool.rebalancePosition(pid, force: true)`.
- Result:
  - Both the AutoBalancer and the FlowALP position are adjusted **in that single run**, whether manual `rebalanceTide` or scheduled child.



#### 6.3 Both Flow and Yield move

- If Yield changes enough, AutoBalancer will rebalance.
- The FlowALP position's health also changes from Flow's move.
- The AutoBalancer-induced deposit into the position will cause:
  - `rebalancePosition(pid, force: true)` in FlowALP.
- So scheduled children become effective, **as long as there is Yield-side value movement**.



---



### 7. Key Answers to Your Specific Questions



1. **"Are we rebalancing both the position and the AutoBalancer together, like in the tests?"**  
   - **Sometimes.**  
   - A `rebalanceTide` / scheduled child always calls `AutoBalancer.rebalance(force)`.  
   - If AutoBalancer sees real `valueDiff` and has its sink wired (which we do), it:
     - Moves funds via `positionSwapSink` into the FlowALP position.  
     - That deposit path triggers `FlowALP.Pool.rebalancePosition(pid, force: true)`.  
   - So **when** the AutoBalancer actually executes a non-trivial rebalance, **both** are adjusted in that single call/tx.



2. **"Does `rebalanceTide` itself call `rebalancePosition`?"**  
   - **No, not directly.**  
   - It only calls `AutoBalancer.rebalance(force)`.  
   - Position rebalancing happens **indirectly** via the connector graph and FlowALP's `pushToDrawDownSink` logic.



3. **"In `rebalance_scenario3a_test.cdc`, if we remove `rebalancePosition`, will it behave the same?"**  
   - **No, especially for the first leg.**  
   - You change **Flow price** (collateral) but keep Yield price at 1.0.  
   - AutoBalancer sees `valueDiff == 0` and does nothing.  
   - The only thing that actually updates the position in that segment is `FlowALP.Pool.rebalancePosition(pid, force: true)` called via your explicit `rebalancePosition` helper.  
   - Later, after you change **Yield** price, `rebalanceTide` alone is sufficient because now the AutoBalancer sees `valueDiff > 0` and pushes value into the position.



4. **"How does this relate to scheduled transactions?"**  
   - A scheduled child is just **"call the AutoBalancer's handler at time T with some `data` (including `force`)"**.  
   - This is semantically equivalent to manually doing `rebalanceTide` at that time.  
   - If `valueDiff == 0`, scheduled runs are **no-ops** regarding AutoBalancer and position, though you still pay fees and see scheduler events.  
   - If `valueDiff > 0`, the scheduled run behaves like a manual `rebalanceTide` that triggers both AutoBalancer and FlowALP position changes.



5. **"If Flow collateral value changes but Yield price does not, will scheduled rebalancing affect the FlowALP position?"**  
   - **No, not via the current scheduling path.**  
   - The AutoBalancer's notion of `valueDiff` is only sensitive to the Yield side (its own vault and oracle).  
   - Therefore, **Flow-only price changes do not trigger AutoBalancer rebalance**, and so scheduled children do not touch the FlowALP position in that case.



6. **"If we want FlowALP positions to rebalance directly on collateral moves, what then?"**  
   - You would need **separate scheduling for FlowALP positions**, using FlowALP's own `rebalancePosition(pid, force)` as the handler.  
   - Architecturally, this belongs in **FlowALP / FlowActions**, since it is a position-health concern of the lending protocol, not of FlowVaults/Tides.  
   - FlowVaults should then just integrate with FlowALP as a client, not own its health-scheduling logic.



---



This captures the complete technical picture we walked through: how Tides, AutoBalancers, FlowALP positions, and scheduled transactions interact; precisely when both AutoBalancer and position move together; and when they do not. You can drop this into a doc for your colleagues as a reference on the current design and its implications.


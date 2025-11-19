## FlowALP Scheduled Liquidations – Architecture & PR Notes

This document summarizes the design and wiring of the automated, perpetual liquidation scheduling system for FlowALP, implemented on the `scheduled-liquidations` branch.

The goal is to mirror the proven FlowVaults Tides rebalancing scheduler architecture while targeting FlowALP positions and keeping the core FlowALP storage layout unchanged.

---

## High-Level Architecture

- **Global Supervisor**
  - `FlowALPLiquidationScheduler.Supervisor` is a `FlowTransactionScheduler.TransactionHandler`.
  - Runs as a single global job that fans out per-position liquidation children across all registered markets.
  - Reads markets and positions from `FlowALPSchedulerRegistry`.
  - For each registered market:
    - Pulls registered position IDs for that market.
    - Filters to currently liquidatable positions via `FlowALPLiquidationScheduler.isPositionLiquidatable`.
    - Schedules child liquidation jobs via per-market wrapper capabilities, respecting a per-run bound (`maxPositionsPerMarket`).
  - Supports optional recurrence:
    - If configured, the supervisor self-reschedules using its own capability stored in `FlowALPSchedulerRegistry`.
    - Recurrence is driven by configuration embedded in the `data` payload of the scheduled transaction.

- **Per-Market Liquidation Handler**
  - `FlowALPLiquidationScheduler.LiquidationHandler` is a `FlowTransactionScheduler.TransactionHandler`.
  - One instance is created per (logical) FlowALP market.
  - Fields:
    - `marketID: UInt64` – logical market identifier for events/proofs.
    - `feesCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>` – pays scheduler fees and receives seized collateral.
    - `debtVaultCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>` – pulls debt tokens (e.g. MOET) used to repay liquidations.
    - `debtType: Type` – defaulted to `@MOET.Vault`.
    - `seizeType: Type` – defaulted to `@FlowToken.Vault`.
  - `executeTransaction(id, data)`:
    - Decodes a configuration map:
      - `marketID`, `positionID`, `isRecurring`, `recurringInterval`, `priority`, `executionEffort`.
    - Borrows the `FlowALP.Pool` from its canonical storage path.
    - Skips gracefully (but still records proof) if the position is no longer liquidatable or if the quote indicates `requiredRepay <= 0.0`.
    - Otherwise:
      - Quotes liquidation via `pool.quoteLiquidation`.
      - Withdraws debt tokens from `debtVaultCap` to repay the position’s debt.
      - Executes `pool.liquidateRepayForSeize` and:
        - Deposits seized collateral into the FlowToken vault referenced by `feesCap`.
        - Returns unused debt tokens to the debt keeper vault.
    - Records execution via `FlowALPSchedulerProofs.markExecuted`.
    - Delegates recurrence bookkeeping to `FlowALPLiquidationScheduler.scheduleNextIfRecurring`.

- **Liquidation Manager (Schedule Metadata)**
  - `FlowALPLiquidationScheduler.LiquidationManager` is a separate resource stored in the scheduler account.
  - Tracks:
    - `scheduleData: {UInt64: LiquidationScheduleData}` keyed by scheduled transaction ID.
    - `scheduledByPosition: {UInt64: {UInt64: UInt64}}` mapping `(marketID -> (positionID -> scheduledTxID))`.
  - Responsibilities:
    - Avoids duplicate scheduling:
      - `hasScheduled(marketID, positionID)` performs cleanup on executed/canceled or missing schedules and returns whether there is an active schedule.
    - Returns schedule metadata by ID or by (marketID, positionID).
    - Used by:
      - `scheduleLiquidation` to enforce uniqueness and store metadata.
      - `isAlreadyScheduled` helper.
      - `scheduleNextIfRecurring` to fetch recurrence config and create the next child job.

- **Registry Contract**
  - `FlowALPSchedulerRegistry` stores:
    - `registeredMarkets: {UInt64: Bool}`.
    - `wrapperCaps: {UInt64: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>}` – per-market `LiquidationHandler` caps.
    - `supervisorCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>?` – global supervisor capability, used for self-rescheduling.
    - `positionsByMarket: {UInt64: {UInt64: Bool}}` – optional position registry keyed by market.
  - API:
    - `registerMarket(marketID, wrapperCap)` / `unregisterMarket(marketID)`.
    - `getRegisteredMarketIDs(): [UInt64]`.
    - `getWrapperCap(marketID): Capability<...>?`.
    - `setSupervisorCap` / `getSupervisorCap`.
    - `registerPosition(marketID, positionID)` / `unregisterPosition(marketID, positionID)`.
    - `getPositionIDsForMarket(marketID): [UInt64]`.
  - Position registry is intentionally separate from FlowALP core:
    - Populated via dedicated transactions (see integration points below).
    - Allows the Supervisor to enumerate candidate positions without reading FlowALP internal storage.

- **Proofs Contract**
  - `FlowALPSchedulerProofs` is a storage-only contract for executed liquidation proofs.
  - Events:
    - `LiquidationScheduled(marketID, positionID, scheduledTransactionID, timestamp)` (defined, not currently relied upon in tests).
    - `LiquidationExecuted(marketID, positionID, scheduledTransactionID, timestamp)` (defined, not currently relied upon in tests).
  - Storage:
    - `executedByPosition: {UInt64: {UInt64: {UInt64: Bool}}}` – mapping:
      - `marketID -> positionID -> scheduledTransactionID -> true`.
  - API:
    - `markExecuted(marketID, positionID, scheduledTransactionID)` – called by `LiquidationHandler` on successful (or intentionally no-op) execution.
    - `wasExecuted(marketID, positionID, scheduledTransactionID): Bool`.
    - `getExecutedIDs(marketID, positionID): [UInt64]`.
  - Tests and scripts read proofs via these helpers for deterministic verification.

---

## Scheduler Contract – Public Surface

`FlowALPLiquidationScheduler` exposes:

- **Supervisor & Handlers**
  - `fun createSupervisor(): @Supervisor`
    - Ensures `LiquidationManager` is present in storage and publishes a capability for it.
    - Issues a FlowToken fee vault capability for scheduler fees.
  - `fun deriveSupervisorPath(): StoragePath`
    - Deterministic storage path per scheduler account for the Supervisor resource.
  - `fun createMarketWrapper(marketID: UInt64): @LiquidationHandler`
    - Creates a per-market `LiquidationHandler` configured to repay with MOET and seize FlowToken.
  - `fun deriveMarketWrapperPath(marketID: UInt64): StoragePath`
    - Storage path for the handler resource per logical market.

- **Scheduling Helpers**
  - `fun scheduleLiquidation(handlerCap, marketID, positionID, timestamp, priority, executionEffort, fees, isRecurring, recurringInterval?): UInt64`
    - Core primitive that:
      - Prevents duplicates per (marketID, positionID).
      - Calls `FlowTransactionScheduler.schedule`.
      - Saves metadata into `LiquidationManager`.
      - Emits `LiquidationChildScheduled` (scheduler-level event).
  - `fun estimateSchedulingCost(timestamp, priority, executionEffort): FlowTransactionScheduler.EstimatedScheduledTransaction`
    - Thin wrapper around `FlowTransactionScheduler.estimate`.
  - `fun scheduleNextIfRecurring(completedID, marketID, positionID)`
    - Looks up `LiquidationScheduleData` for `completedID`.
    - If non-recurring, clears metadata and returns.
    - If recurring, computes `nextTimestamp = now + interval`, re-estimates fees, and re-schedules a new child job via the appropriate `LiquidationHandler` capability.
  - `fun isAlreadyScheduled(marketID, positionID): Bool`
    - Convenience helper for scripts and tests.
  - `fun getScheduledLiquidation(marketID, positionID): LiquidationScheduleInfo?`
    - Structured view of current scheduled liquidation for a given (marketID, positionID), including scheduler status.

- **Registration Utilities**
  - `fun registerMarket(marketID: UInt64)`
    - Idempotent:
      - Ensures a per-market `LiquidationHandler` is stored under `deriveMarketWrapperPath(marketID)`.
      - Issues its `TransactionHandler` capability and stores it in `FlowALPSchedulerRegistry.registerMarket`.
  - `fun unregisterMarket(marketID: UInt64)`
    - Deletes registry entries for the given market.
  - `fun getRegisteredMarketIDs(): [UInt64]`
    - Passthrough to `FlowALPSchedulerRegistry.getRegisteredMarketIDs`.
  - `fun isPositionLiquidatable(positionID: UInt64): Bool`
    - Borrow `FlowALP.Pool` and call `pool.isLiquidatable(pid: positionID)`.
    - Used by Supervisor, scripts, and tests to identify underwater positions.

---

## Integration with FlowALP (No Core Storage Changes)

The integration is deliberately isolated to helper contracts and test-only transactions, keeping the core `FlowALP` storage layout unchanged.

- **Market Creation**
  - `lib/FlowALP/cadence/transactions/alp/create_market.cdc`
    - Uses `FlowALP.PoolFactory` to create the FlowALP Pool (idempotently).
    - Accepts:
      - `defaultTokenIdentifier: String` – e.g. `A.045a1763c93006ca.MOET.Vault`.
      - `marketID: UInt64` – logical identifier for the market.
    - After ensuring the pool exists, calls:
      - `FlowALPLiquidationScheduler.registerMarket(marketID: marketID)`
    - This auto-registers the market with the scheduler registry; no extra manual step is required for new markets.

- **Position Opening & Tracking**
  - `lib/FlowALP/cadence/transactions/alp/open_position_for_market.cdc`
    - Opens a FlowALP position and registers it for liquidation scheduling.
    - Flow:
      - Borrow `FlowALP.Pool` from the signer’s storage.
      - Withdraw `amount` of FlowToken from the signer’s vault.
      - Create a MOET vault sink using `FungibleTokenConnectors.VaultSink`.
      - Call:
        - `let pid = pool.createPosition(...)`.
        - `pool.rebalancePosition(pid: pid, force: true)`.
      - Register the new position in the scheduler registry:
        - `FlowALPSchedulerRegistry.registerPosition(marketID: marketID, positionID: pid)`.
    - Result:
      - Supervisor can iterate over `FlowALPSchedulerRegistry.getPositionIDsForMarket(marketID)` and then use `isPositionLiquidatable` to find underwater candidates.
  - Optional close hooks:
    - `FlowALPSchedulerRegistry.unregisterPosition(marketID, positionID)` is available for future integration with position close transactions but is not required for these tests.

- **Underwater Discovery (Read-Only)**
  - `lib/FlowALP/cadence/scripts/alp/get_underwater_positions.cdc`
    - Uses the on-chain registry + FlowALP health to find underwater positions per market:
      - `getPositionIDsForMarket(marketID)` from registry.
      - Filters via `FlowALPLiquidationScheduler.isPositionLiquidatable(pid)`.
    - Primarily used in E2E tests to:
      - Validate that price changes cause positions to become underwater.
      - Select candidate positions for targeted liquidation tests.

---

## Transactions & Scripts

### Scheduler Setup & Control

- **`setup_liquidation_supervisor.cdc`**
  - Creates and stores the global `Supervisor` resource at `FlowALPLiquidationScheduler.deriveSupervisorPath()` in the scheduler account (tidal).
  - Issues the supervisor’s `TransactionHandler` capability and saves it into `FlowALPSchedulerRegistry.setSupervisorCap`.
  - Idempotent: will not overwrite an existing Supervisor.

- **`schedule_supervisor.cdc`**
  - Schedules the Supervisor into `FlowTransactionScheduler`.
  - Arguments:
    - `timestamp`: first run time (usually now + a few seconds).
    - `priorityRaw`: 0/1/2 → High/Medium/Low.
    - `executionEffort`: computational effort hint.
    - `feeAmount`: FlowToken to cover the scheduler fee.
    - `recurringInterval`: seconds between Supervisor runs (0 to disable recurrence).
    - `maxPositionsPerMarket`: per-run bound for positions per market.
    - `childRecurring`: whether per-position liquidations should be recurring.
    - `childInterval`: recurrence interval for child jobs.
  - Encodes config into a `{String: AnyStruct}` and passes it to the Supervisor handler.

- **`schedule_liquidation.cdc`**
  - Manual, per-position fallback scheduler.
  - Fetches per-market handler capability from `FlowALPSchedulerRegistry.getWrapperCap(marketID)`.
  - Withdraws FlowToken fees from the signer.
  - Calls `FlowALPLiquidationScheduler.scheduleLiquidation(...)`.
  - Supports both one-off and recurring jobs via `isRecurring` / `recurringInterval`.

### Market & Position Helpers

- **`create_market.cdc`**
  - Creates the FlowALP Pool if not present and auto-registers the `marketID` in `FlowALPLiquidationScheduler` / `FlowALPSchedulerRegistry`.

- **`open_position_for_market.cdc`**
  - Opens a FlowALP position for a given market and registers it in `FlowALPSchedulerRegistry` for supervisor discovery.

### Scripts

- **`get_registered_market_ids.cdc`**
  - Returns all scheduler-registered market IDs.

- **`get_scheduled_liquidation.cdc`**
  - Thin wrapper over `FlowALPLiquidationScheduler.getScheduledLiquidation(marketID, positionID)`.
  - Used in tests to obtain the scheduled transaction ID for a (marketID, positionID) pair.

- **`estimate_liquidation_cost.cdc`**
  - Wraps `FlowALPLiquidationScheduler.estimateSchedulingCost`.
  - Lets tests pre-estimate `flowFee` and add a small buffer to avoid underpayment.

- **`get_liquidation_proof.cdc`**
  - Calls `FlowALPSchedulerProofs.wasExecuted(marketID, positionID, scheduledTransactionID)`.
  - Serves as an on-chain proof of execution for tests.

- **`get_executed_liquidations_for_position.cdc`**
  - Returns all executed scheduled transaction IDs for a given (marketID, positionID).
  - Used in multi-market supervisor tests.

- **`get_underwater_positions.cdc`**
  - Read-only helper returning underwater positions for a given market ID, based on registry and `FlowALPLiquidationScheduler.isPositionLiquidatable`.

---

## E2E Test Setup & Runners

All E2E tests assume:

- Flow emulator running with scheduled transactions enabled.
- The `tidal` account deployed with:
  - FlowALP + MOET.
  - `FlowALPSchedulerRegistry`, `FlowALPSchedulerProofs`, `FlowALPLiquidationScheduler`.
  - FlowVaults contracts and their scheduler (already covered by previous work, reused for status polling helpers).

### Emulator Start Script

- **`local/start_emulator_liquidations.sh`**
  - Convenience wrapper:
    - Navigates to repo root.
    - Executes `local/start_emulator_scheduled.sh`.
  - The underlying `start_emulator_scheduled.sh` runs:
    - `flow emulator --scheduled-transactions --block-time 1s` with the service key from `local/emulator-account.pkey`.
  - Intended usage:
    - Terminal 1: `./local/start_emulator_liquidations.sh`.
    - Terminal 2: run one of the E2E test scripts below.

### Single-Market Liquidation Test

- **`run_single_market_liquidation_test.sh`**
  - Flow:
    1. Wait for emulator on port 3569.
    2. Run `local/setup_wallets.sh` and `local/setup_emulator.sh` (idempotent).
    3. Ensure MOET vault exists for `tidal`.
    4. Run `setup_liquidation_supervisor.cdc` to create and register the Supervisor.
    5. Create a single market via `create_market.cdc` (`marketID=0`).
    6. Open one FlowALP position in that market via `open_position_for_market.cdc` (`positionID=0`).
    7. Drop FlowToken oracle price to make the position undercollateralised.
    8. Estimate scheduling cost via `estimate_liquidation_cost.cdc` and add a small buffer.
    9. Schedule a single liquidation via `schedule_liquidation.cdc`.
    10. Fetch the scheduled transaction ID using `get_scheduled_liquidation.cdc`.
    11. Poll `FlowTransactionScheduler` status via `cadence/scripts/flow-vaults/get_scheduled_tx_status.cdc`, with graceful handling of nil status.
    12. Read execution proof via `get_liquidation_proof.cdc`.
    13. Compare position health before/after via `cadence/scripts/flow-alp/position_health.cdc`.
  - Assertions:
    - Scheduler status transitions to Executed or disappears (nil) while an `Executed` event exists in the block window, or an on-chain proof is present.
    - Position health improves and is at least `1.0` after liquidation.

### Multi-Market Supervisor Fan-Out Test

- **`run_multi_market_supervisor_liquidations_test.sh`**
  - Flow:
    1. Wait for emulator, run wallet + emulator setup, ensure MOET vault and Supervisor exist.
    2. Create multiple markets (currently two: `0` and `1`) via `create_market.cdc`.
    3. Open positions in each market via `open_position_for_market.cdc`.
    4. Drop FlowToken oracle price to put positions underwater.
    5. Capture initial health for each position.
    6. Estimate Supervisor scheduling cost and schedule a single Supervisor run via `schedule_supervisor.cdc`.
    7. Sleep ~25 seconds to allow Supervisor and child jobs to execute.
    8. Check `FlowTransactionScheduler.Executed` events in the block window.
    9. For each (marketID, positionID), call `get_executed_liquidations_for_position.cdc` to ensure each has at least one executed ID.
    10. Re-check position health; assert it improved and is at least `1.0`.
  - Validates:
    - Global Supervisor fan-out across multiple registered markets.
    - Per-market wrapper capabilities and LiquidationHandlers are used correctly.
    - Observed health improvement and asset movement (via seized collateral).

### Auto-Register Market + Liquidation Test

- **`run_auto_register_market_liquidation_test.sh`**
  - Flow:
    1. Wait for emulator, run wallet + emulator setup, ensure MOET vault and Supervisor exist.
    2. Fetch currently registered markets via `get_registered_market_ids.cdc`.
    3. Choose a new `marketID = max(existing) + 1` (or 0 if none).
    4. Create the new market via `create_market.cdc` (auto-registers with scheduler).
    5. Verify the new market ID shows up in `get_registered_market_ids.cdc`.
    6. Open a position in the new market via `open_position_for_market.cdc`.
    7. Drop FlowToken oracle price and call `get_underwater_positions.cdc` to identify an underwater position.
    8. Capture initial position health.
    9. Try to seed child liquidations via Supervisor:
       - Up to two attempts:
         - For each attempt:
           - Estimate fee and schedule Supervisor with short lookahead and recurrence enabled.
           - Sleep ~20 seconds.
           - Query `get_scheduled_liquidation.cdc` for the new market/position pair.
    10. If no child job appears, fall back to manual `schedule_liquidation.cdc`.
    11. Once a scheduled ID exists, poll scheduler status and on-chain proofs similar to the single-market test.
    12. Verify health improvement as in previous tests.
  - Validates:
    - Market auto-registration via `create_market.cdc`.
    - Supervisor-based seeding of child jobs for newly registered markets.
    - Robustness via retries and a manual fallback path.

---

## Emulator & Idempotency Notes

- `local/setup_emulator.sh`:
  - Updates the FlowALP `FlowActions` submodule (if needed) and deploys all core contracts (FlowALP, MOET, FlowVaults, schedulers, etc.) to the emulator.
  - Configures:
    - Mock oracle prices and liquidity sources.
    - FlowALP pool and supported tokens.
  - Intended to be idempotent; repeated calls should not break state.
- Test scripts:
  - Guard critical setup commands with `|| true` where safe to avoid flakiness if rerun.
  - Handle nil or missing scheduler statuses gracefully.

---

## Known Limitations / Future Enhancements

- Position registry:
  - Positions are tracked per market in `FlowALPSchedulerRegistry`.
  - Position closures are not yet wired to `unregisterPosition`, so the registry may include closed positions in long-lived environments.
  - Mitigation:
    - Supervisor and `LiquidationHandler` both check `isPositionLiquidatable` and skip cleanly when not liquidatable.
- Bounded enumeration:
  - Supervisor currently enforces a per-market bound via `maxPositionsPerMarket` but does not yet implement chunked iteration over very large position sets (beyond tests’ needs).
  - Recurring Supervisor runs can be used to cover large sets over time.
- Fees and buffers:
  - Tests add a small fixed buffer on top of the estimated `flowFee`.
  - Production environments may want more robust fee-buffering logic (e.g. multiplier or floor).
- Events vs proofs:
  - The main verification channel is the proofs map in `FlowALPSchedulerProofs` plus scheduler status and global FlowTransactionScheduler events.
  - `LiquidationScheduled` / `LiquidationExecuted` events in `FlowALPSchedulerProofs` are defined but not strictly required by the current tests.

---

## Work State & How to Re-Run

This section is intended to help future maintainers or tooling resume work quickly if interrupted.

- **Branches**
  - Root repo (`tidal-sc`): `scheduled-liquidations` (branched from `scheduled-rebalancing`).
  - FlowALP sub-repo (`lib/FlowALP`): `scheduled-liquidations`.
- **Key Contracts & Files**
  - Scheduler contracts:
    - `lib/FlowALP/cadence/contracts/FlowALPLiquidationScheduler.cdc`
    - `lib/FlowALP/cadence/contracts/FlowALPSchedulerRegistry.cdc`
    - `lib/FlowALP/cadence/contracts/FlowALPSchedulerProofs.cdc`
  - Scheduler transactions:
    - `lib/FlowALP/cadence/transactions/alp/setup_liquidation_supervisor.cdc`
    - `lib/FlowALP/cadence/transactions/alp/schedule_supervisor.cdc`
    - `lib/FlowALP/cadence/transactions/alp/schedule_liquidation.cdc`
    - `lib/FlowALP/cadence/transactions/alp/create_market.cdc`
    - `lib/FlowALP/cadence/transactions/alp/open_position_for_market.cdc`
  - Scheduler scripts:
    - `lib/FlowALP/cadence/scripts/alp/get_registered_market_ids.cdc`
    - `lib/FlowALP/cadence/scripts/alp/get_scheduled_liquidation.cdc`
    - `lib/FlowALP/cadence/scripts/alp/estimate_liquidation_cost.cdc`
    - `lib/FlowALP/cadence/scripts/alp/get_liquidation_proof.cdc`
    - `lib/FlowALP/cadence/scripts/alp/get_executed_liquidations_for_position.cdc`
    - `lib/FlowALP/cadence/scripts/alp/get_underwater_positions.cdc`
  - E2E harness:
    - `local/start_emulator_liquidations.sh`
    - `run_single_market_liquidation_test.sh`
    - `run_multi_market_supervisor_liquidations_test.sh`
    - `run_auto_register_market_liquidation_test.sh`
- **To (Re)Run Tests (from a fresh emulator)**
  - Terminal 1:
    - `./local/start_emulator_liquidations.sh`
  - Terminal 2:
    - Single market: `./run_single_market_liquidation_test.sh`
    - Multi-market supervisor: `./run_multi_market_supervisor_liquidations_test.sh`
    - Auto-register: `./run_auto_register_market_liquidation_test.sh`

## Test Results (emulator fresh-start)

- **Single-market scheduled liquidation**: PASS (position health improves from \<1.0 to \>1.0, proof recorded, fees paid via scheduler).
- **Multi-market supervisor fan-out**: PASS (Supervisor schedules child liquidations for all registered markets; proofs present and position health improves to \>1.0). For reproducibility, run on a fresh emulator to avoid residual positions from earlier runs.
- **Auto-register market liquidation**: PASS (newly created market auto-registers in the registry; Supervisor schedules a child job for its underwater position, with proof + health improvement asserted). Also recommended to run from a fresh emulator.

 

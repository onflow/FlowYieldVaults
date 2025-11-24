// standards
import "FungibleToken"
import "FlowToken"
// Flow system contracts
import "FlowTransactionScheduler"
// DeFiActions
import "DeFiActions"
import "FlowVaultsAutoBalancers"
// Registry storage (separate contract)
import "FlowVaultsSchedulerRegistry"

/// FlowVaultsScheduler
///
/// This contract enables the scheduling of autonomous rebalancing transactions for FlowVaults Tides.
/// It integrates with Flow's FlowTransactionScheduler to schedule periodic rebalancing operations
/// on AutoBalancers associated with specific Tide IDs.
///
/// Key Features:
/// - Schedule one-time or recurring rebalancing transactions
/// - Cancel scheduled rebalancing transactions
/// - Query scheduled transactions and their status
/// - Estimate scheduling costs before committing funds
///
access(all) contract FlowVaultsScheduler {

    /* --- PATHS --- */

    /// Storage path for the SchedulerManager resource
    access(all) let SchedulerManagerStoragePath: StoragePath
    /// Public path for the SchedulerManager public interface
    access(all) let SchedulerManagerPublicPath: PublicPath

    /* --- EVENTS --- */

    /// Emitted when a rebalancing transaction is scheduled for a Tide
    access(all) event RebalancingScheduled(
        tideID: UInt64,
        scheduledTransactionID: UInt64,
        timestamp: UFix64,
        priority: UInt8,
        isRecurring: Bool,
        recurringInterval: UFix64?,
        force: Bool
    )

    /// Emitted when a scheduled rebalancing transaction is canceled
    access(all) event RebalancingCanceled(
        tideID: UInt64,
        scheduledTransactionID: UInt64,
        feesReturned: UFix64
    )

    /// Emitted when a scheduled rebalancing transaction is executed
    access(all) event RebalancingExecuted(
        tideID: UInt64,
        scheduledTransactionID: UInt64,
        timestamp: UFix64
    )

    /* --- STRUCTS --- */

    /// RebalancingScheduleInfo contains information about a scheduled rebalancing transaction
    access(all) struct RebalancingScheduleInfo {
        access(all) let tideID: UInt64
        access(all) let scheduledTransactionID: UInt64
        access(all) let timestamp: UFix64
        access(all) let priority: FlowTransactionScheduler.Priority
        access(all) let isRecurring: Bool
        access(all) let recurringInterval: UFix64?
        access(all) let force: Bool
        access(all) let status: FlowTransactionScheduler.Status?

        init(
            tideID: UInt64,
            scheduledTransactionID: UInt64,
            timestamp: UFix64,
            priority: FlowTransactionScheduler.Priority,
            isRecurring: Bool,
            recurringInterval: UFix64?,
            force: Bool,
            status: FlowTransactionScheduler.Status?
        ) {
            self.tideID = tideID
            self.scheduledTransactionID = scheduledTransactionID
            self.timestamp = timestamp
            self.priority = priority
            self.isRecurring = isRecurring
            self.recurringInterval = recurringInterval
            self.force = force
            self.status = status
        }
    }

    /// RebalancingScheduleData is stored internally to track scheduled transactions
    access(all) struct RebalancingScheduleData {
        access(all) let tideID: UInt64
        access(all) let isRecurring: Bool
        access(all) let recurringInterval: UFix64?
        access(all) let force: Bool

        init(
            tideID: UInt64,
            isRecurring: Bool,
            recurringInterval: UFix64?,
            force: Bool
        ) {
            self.tideID = tideID
            self.isRecurring = isRecurring
            self.recurringInterval = recurringInterval
            self.force = force
        }
    }

    /* --- RESOURCES --- */

    /// Wrapper handler that emits a scheduler-level execution event while delegating to the target handler
    access(all) resource RebalancingHandler: FlowTransactionScheduler.TransactionHandler {
        /// Capability pointing at the actual TransactionHandler (AutoBalancer)
        access(self) let target: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
        /// The Tide ID this handler corresponds to
        access(self) let tideID: UInt64

        init(
            target: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
            tideID: UInt64
        ) {
            self.target = target
            self.tideID = tideID
        }

        /// Called by FlowTransactionScheduler when the scheduled tx executes
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let ref = self.target.borrow()
                ?? panic("Invalid target TransactionHandler capability for Tide #".concat(self.tideID.toString()))
            // delegate to the underlying handler (AutoBalancer)
            ref.executeTransaction(id: id, data: data)
            // if recurring, schedule the next
            FlowVaultsScheduler.scheduleNextIfRecurring(completedID: id, tideID: self.tideID)
            // emit wrapper-level execution signal for test observability
            emit RebalancingExecuted(
                tideID: self.tideID,
                scheduledTransactionID: id,
                timestamp: getCurrentBlock().timestamp
            )
        }
    }

    /// SchedulerManager manages scheduled rebalancing transactions for multiple Tides
    access(all) resource SchedulerManager {
        /// Maps Tide IDs to their scheduled transaction resources
        access(self) let scheduledTransactions: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}
        /// Maps scheduled transaction IDs to rebalancing schedule data
        access(self) let scheduleData: {UInt64: RebalancingScheduleData}

        init() {
            self.scheduledTransactions <- {}
            self.scheduleData = {}
        }

        /// Schedules a rebalancing transaction for a specific Tide
        ///
        /// @param handlerCap: A capability to the AutoBalancer that implements TransactionHandler
        /// @param tideID: The ID of the Tide to schedule rebalancing for
        /// @param timestamp: The Unix timestamp when the rebalancing should occur
        /// @param priority: The priority level (High, Medium, or Low)
        /// @param executionEffort: The computational effort allocated for execution
        /// @param fees: Flow tokens to pay for the scheduled transaction
        /// @param force: Whether to force rebalancing regardless of thresholds
        /// @param isRecurring: Whether this should be a recurring rebalancing
        /// @param recurringInterval: If recurring, the interval in seconds between executions
        ///
        access(all) fun scheduleRebalancing(
            handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
            tideID: UInt64,
            timestamp: UFix64,
            priority: FlowTransactionScheduler.Priority,
            executionEffort: UInt64,
            fees: @FlowToken.Vault,
            force: Bool,
            isRecurring: Bool,
            recurringInterval: UFix64?
        ) {
            // Cleanup any executed/removed entry for this tideID
            let existingRef = &self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction?
            if existingRef != nil {
                let st = FlowTransactionScheduler.getStatus(id: existingRef!.id)
                if st == nil || st!.rawValue == 2 {
                    let old <- self.scheduledTransactions.remove(key: tideID)
                        ?? panic("scheduleRebalancing: cleanup remove failed")
                    destroy old
                }
            }
            // Validate inputs (explicit checks instead of `pre` since cleanup precedes)
            if (&self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction?) != nil {
                panic("Rebalancing is already scheduled for Tide #".concat(tideID.toString()).concat(". Cancel the existing schedule first."))
            }
            if isRecurring {
                if recurringInterval == nil || recurringInterval! <= 0.0 {
                    panic("Recurring interval must be greater than 0 when isRecurring is true")
                }
            }
            if !handlerCap.check() {
                panic("Invalid handler capability provided")
            }

            // Schedule the transaction with force parameter in data
            let data: {String: AnyStruct} = {"force": force}
            let scheduledTx <- FlowTransactionScheduler.schedule(
                handlerCap: handlerCap,
                data: data,
                timestamp: timestamp,
                priority: priority,
                executionEffort: executionEffort,
                fees: <-fees
            )

            // Store the schedule information
            let scheduleInfo = RebalancingScheduleData(
                tideID: tideID,
                isRecurring: isRecurring,
                recurringInterval: recurringInterval,
                force: force
            )
            self.scheduleData[scheduledTx.id] = scheduleInfo

            emit RebalancingScheduled(
                tideID: tideID,
                scheduledTransactionID: scheduledTx.id,
                timestamp: timestamp,
                priority: priority.rawValue,
                isRecurring: isRecurring,
                recurringInterval: recurringInterval,
                force: force
            )

            // Store the scheduled transaction
            self.scheduledTransactions[tideID] <-! scheduledTx
        }

        /// Cancels a scheduled rebalancing transaction for a specific Tide
        ///
        /// @param tideID: The ID of the Tide whose scheduled rebalancing should be canceled
        /// @return The refunded fees
        ///
        access(all) fun cancelRebalancing(tideID: UInt64): @FlowToken.Vault {
            pre {
                self.scheduledTransactions[tideID] != nil:
                    "No scheduled rebalancing found for Tide #\(tideID)"
            }

            // Remove the scheduled transaction
            let scheduledTx <- self.scheduledTransactions.remove(key: tideID)
                ?? panic("Could not remove scheduled transaction for Tide #\(tideID)")

            let txID = scheduledTx.id

            // Cancel the scheduled transaction and get the refund
            let refund <- FlowTransactionScheduler.cancel(scheduledTx: <-scheduledTx)

            // Clean up the schedule data
            let _removed = self.scheduleData.remove(key: txID)

            emit RebalancingCanceled(
                tideID: tideID,
                scheduledTransactionID: txID,
                feesReturned: refund.balance
            )

            return <-refund
        }

        /// Returns information about all scheduled rebalancing transactions
        access(all) fun getAllScheduledRebalancing(): [RebalancingScheduleInfo] {
            let schedules: [RebalancingScheduleInfo] = []
            
            for tideID in self.scheduledTransactions.keys {
                let txRef = &self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction?
                if txRef != nil {
                    let data = self.scheduleData[txRef!.id]
                    if data != nil {
                        schedules.append(RebalancingScheduleInfo(
                            tideID: data!.tideID,
                            scheduledTransactionID: txRef!.id,
                            timestamp: txRef!.timestamp,
                            priority: FlowTransactionScheduler.getTransactionData(id: txRef!.id)?.priority
                                ?? FlowTransactionScheduler.Priority.Low,
                            isRecurring: data!.isRecurring,
                            recurringInterval: data!.recurringInterval,
                            force: data!.force,
                            status: FlowTransactionScheduler.getStatus(id: txRef!.id)
                        ))
                    }
                }
            }
            
            return schedules
        }

        /// Returns information about a scheduled rebalancing transaction for a specific Tide
        access(all) fun getScheduledRebalancing(tideID: UInt64): RebalancingScheduleInfo? {
            if let scheduledTx = &self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction? {
                if let data = self.scheduleData[scheduledTx.id] {
                    return RebalancingScheduleInfo(
                        tideID: data.tideID,
                        scheduledTransactionID: scheduledTx.id,
                        timestamp: scheduledTx.timestamp,
                        priority: FlowTransactionScheduler.getTransactionData(id: scheduledTx.id)?.priority
                            ?? FlowTransactionScheduler.Priority.Low,
                        isRecurring: data.isRecurring,
                        recurringInterval: data.recurringInterval,
                        force: data.force,
                        status: FlowTransactionScheduler.getStatus(id: scheduledTx.id)
                    )
                }
            }
            return nil
        }

        /// Returns the Tide IDs that have scheduled rebalancing
        access(all) view fun getScheduledTideIDs(): [UInt64] {
            return self.scheduledTransactions.keys
        }
        
        /// Returns true if a Tide currently has a scheduled rebalancing
        access(all) fun hasScheduled(tideID: UInt64): Bool {
            let txRef = &self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction?
            if txRef == nil {
                return false
            }
            let status = FlowTransactionScheduler.getStatus(id: txRef!.id)
            if status == nil {
                return false
            }
            // If one-time and already executed, treat as not scheduled
            if let data = self.scheduleData[txRef!.id] {
                if !data.isRecurring && status!.rawValue == 2 {
                    return false
                }
            } else {
                if status!.rawValue == 2 {
                    return false
                }
            }
            return true
        }

        /// Returns stored schedule data for a scheduled transaction ID, if present
        access(all) fun getScheduleData(id: UInt64): RebalancingScheduleData? {
            return self.scheduleData[id]
        }
    }

    /// A supervisor handler that ensures all registered tides have a scheduled rebalancing
    access(all) resource Supervisor: FlowTransactionScheduler.TransactionHandler {
        access(self) let managerCap: Capability<&FlowVaultsScheduler.SchedulerManager>
        access(self) let feesCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>

        init(
            managerCap: Capability<&FlowVaultsScheduler.SchedulerManager>,
            feesCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
        ) {
            self.managerCap = managerCap
            self.feesCap = feesCap
        }

        /// data accepts optional config:
        /// {
        ///   "priority": UInt8 (0=High,1=Medium,2=Low),
        ///   "executionEffort": UInt64,
        ///   "lookaheadSecs": UFix64,
        ///   "childRecurring": Bool,
        ///   "childInterval": UFix64,
        ///   "force": Bool,
        ///   "recurringInterval": UFix64
        /// }
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let cfg = data as? {String: AnyStruct} ?? {}
            let priorityRaw = cfg["priority"] as? UInt8 ?? 1
            let executionEffort = cfg["executionEffort"] as? UInt64 ?? 800
            let lookaheadSecs = cfg["lookaheadSecs"] as? UFix64 ?? 5.0
            let childRecurring = cfg["childRecurring"] as? Bool ?? true
            let childInterval = cfg["childInterval"] as? UFix64 ?? 60.0
            let forceChild = cfg["force"] as? Bool ?? false
            let recurringInterval = cfg["recurringInterval"] as? UFix64

            let priority: FlowTransactionScheduler.Priority =
                priorityRaw == 0 ? FlowTransactionScheduler.Priority.High :
                (priorityRaw == 1 ? FlowTransactionScheduler.Priority.Medium : FlowTransactionScheduler.Priority.Low)

            let manager = self.managerCap.borrow()
                ?? panic("Supervisor: missing SchedulerManager")

            // Iterate through registered tides
            for tideID in FlowVaultsSchedulerRegistry.getRegisteredTideIDs() {
                // Skip if already scheduled
                if manager.hasScheduled(tideID: tideID) {
                    continue
                }

                // Get pre-issued wrapper capability for this tide
                let wrapperCap = FlowVaultsSchedulerRegistry.getWrapperCap(tideID: tideID)
                    ?? panic("No wrapper capability for tide ".concat(tideID.toString()))

                // Estimate fee and schedule child
                let ts = getCurrentBlock().timestamp + lookaheadSecs
                let est = FlowVaultsScheduler.estimateSchedulingCost(
                    timestamp: ts,
                    priority: priority,
                    executionEffort: executionEffort
                )
                let required = est.flowFee ?? 0.00005
                let vaultRef = self.feesCap.borrow()
                    ?? panic("Supervisor: cannot borrow FlowToken Vault")
                let pay <- vaultRef.withdraw(amount: required) as! @FlowToken.Vault

                manager.scheduleRebalancing(
                    handlerCap: wrapperCap,
                    tideID: tideID,
                    timestamp: ts,
                    priority: priority,
                    executionEffort: executionEffort,
                    fees: <-pay,
                    force: forceChild,
                    isRecurring: childRecurring,
                    recurringInterval: childRecurring ? childInterval : nil
                )
            }

            // Self-reschedule for perpetual operation if configured
            if let interval = recurringInterval {
                let nextTimestamp = getCurrentBlock().timestamp + interval
                let est = FlowVaultsScheduler.estimateSchedulingCost(
                    timestamp: nextTimestamp,
                    priority: priority,
                    executionEffort: executionEffort
                )
                let required = est.flowFee ?? 0.00005
                let vaultRef = self.feesCap.borrow()
                    ?? panic("Supervisor: cannot borrow FlowToken Vault for self-reschedule")
                let pay <- vaultRef.withdraw(amount: required) as! @FlowToken.Vault

                let supCap = FlowVaultsSchedulerRegistry.getSupervisorCap()
                    ?? panic("Supervisor: missing supervisor capability")

                let _scheduled <- FlowTransactionScheduler.schedule(
                    handlerCap: supCap,
                    data: cfg,
                    timestamp: nextTimestamp,
                    priority: priority,
                    executionEffort: executionEffort,
                    fees: <-pay
                )
                destroy _scheduled
            }
        }
    }

    /// Schedules next rebalancing for a tide if the completed scheduled tx was marked recurring
    access(all) fun scheduleNextIfRecurring(completedID: UInt64, tideID: UInt64) {
        let manager = self.account.storage
            .borrow<&FlowVaultsScheduler.SchedulerManager>(from: self.SchedulerManagerStoragePath)
            ?? panic("scheduleNextIfRecurring: missing SchedulerManager")
        let data = manager.getScheduleData(id: completedID)
        if data == nil {
            return
        }
        if !data!.isRecurring {
            return
        }
        let interval = data!.recurringInterval ?? 60.0
        let priority: FlowTransactionScheduler.Priority = FlowTransactionScheduler.Priority.Medium
        let executionEffort: UInt64 = 800
        let ts = getCurrentBlock().timestamp + interval

        // Ensure wrapper exists and issue cap
        let wrapperPath = self.deriveRebalancingHandlerPath(tideID: tideID)
        if self.account.storage.borrow<&FlowVaultsScheduler.RebalancingHandler>(from: wrapperPath) == nil {
            let abPath = FlowVaultsAutoBalancers.deriveAutoBalancerPath(id: tideID, storage: true) as! StoragePath
            let abCap = self.account.capabilities.storage
                .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(abPath)
            let wrapper <- self.createRebalancingHandler(target: abCap, tideID: tideID)
            self.account.storage.save(<-wrapper, to: wrapperPath)
        }
        let wrapperCap = self.account.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(wrapperPath)

        // Estimate and pay fee
        let est = self.estimateSchedulingCost(
            timestamp: ts,
            priority: priority,
            executionEffort: executionEffort
        )
        let required = est.flowFee ?? 0.00005
        let vaultRef = self.account.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("scheduleNextIfRecurring: cannot borrow FlowToken Vault")
        let pay <- vaultRef.withdraw(amount: required) as! @FlowToken.Vault

        manager.scheduleRebalancing(
            handlerCap: wrapperCap,
            tideID: tideID,
            timestamp: ts,
            priority: priority,
            executionEffort: executionEffort,
            fees: <-pay,
            force: data!.force,
            isRecurring: true,
            recurringInterval: interval
        )
    }

    /* --- PUBLIC FUNCTIONS --- */

    /// Creates a Supervisor handler.
    ///
    /// NOTE: This is restricted to the FlowVaultsScheduler account to prevent
    /// arbitrary users from minting Supervisor instances that carry privileged
    /// capabilities (SchedulerManager + FlowToken vault) for this account.
    access(account) fun createSupervisor(): @Supervisor {
        let mgrCap = self.account.capabilities.storage
            .issue<&FlowVaultsScheduler.SchedulerManager>(self.SchedulerManagerStoragePath)
        let feesCap = self.account.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
        return <- create Supervisor(managerCap: mgrCap, feesCap: feesCap)
    }

    /// Ensures that a global Supervisor exists for this FlowVaults account and
    /// that its capability is registered in the SchedulerRegistry. This is
    /// idempotent and safe to call multiple times.
    access(all) fun ensureSupervisorConfigured() {
        let path = self.deriveSupervisorPath()

        // Create and store the Supervisor resource if it does not yet exist.
        if self.account.storage.borrow<&FlowVaultsScheduler.Supervisor>(from: path) == nil {
            let sup <- self.createSupervisor()
            self.account.storage.save(<-sup, to: path)
        }

        // Issue a capability to the stored Supervisor and record it in the
        // registry so scheduled transactions can reference it.
        let supCap = self.account.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(path)
        FlowVaultsSchedulerRegistry.setSupervisorCap(cap: supCap)
    }

    /// Derives a storage path for the global Supervisor
    access(all) fun deriveSupervisorPath(): StoragePath {
        let identifier = "FlowVaultsScheduler_Supervisor_".concat(self.account.address.toString())
        return StoragePath(identifier: identifier)!
    }

    /// Creates a new RebalancingHandler that wraps a target TransactionHandler (AutoBalancer).
    ///
    /// NOTE: This is restricted to the FlowVaultsScheduler account so that only
    /// the contract owner can mint wrappers that hold capabilities into the
    /// FlowVaults account (AutoBalancer + scheduler state).
    access(account) fun createRebalancingHandler(
        target: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
        tideID: UInt64
    ): @RebalancingHandler {
        return <- create RebalancingHandler(target: target, tideID: tideID)
    }

    /// Derives a storage path for a per-tide RebalancingHandler wrapper
    access(all) fun deriveRebalancingHandlerPath(tideID: UInt64): StoragePath {
        let identifier = "FlowVaultsScheduler_RebalancingHandler_".concat(tideID.toString())
        return StoragePath(identifier: identifier)!
    }

    /// Creates a new SchedulerManager resource
    access(all) fun createSchedulerManager(): @SchedulerManager {
        return <- create SchedulerManager()
    }

    /// Registers a tide to be managed by the Supervisor (idempotent)
    access(account) fun registerTide(tideID: UInt64) {
        // Ensure wrapper exists and store its capability for later scheduling in the registry
        let wrapperPath = self.deriveRebalancingHandlerPath(tideID: tideID)
        if self.account.storage.borrow<&FlowVaultsScheduler.RebalancingHandler>(from: wrapperPath) == nil {
            let abPath = FlowVaultsAutoBalancers.deriveAutoBalancerPath(id: tideID, storage: true) as! StoragePath
            let abCap = self.account.capabilities.storage
                .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(abPath)
            let wrapper <- self.createRebalancingHandler(target: abCap, tideID: tideID)
            self.account.storage.save(<-wrapper, to: wrapperPath)
        }
        let wrapperCap = self.account.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(wrapperPath)
        FlowVaultsSchedulerRegistry.register(tideID: tideID, wrapperCap: wrapperCap)
    }

    /// Unregisters a tide (idempotent) and cleans up pending schedules
    access(account) fun unregisterTide(tideID: UInt64) {
        // 1. Unregister from registry
        FlowVaultsSchedulerRegistry.unregister(tideID: tideID)
        
        // 2. Cancel any pending rebalancing in SchedulerManager
        if let manager = self.account.storage.borrow<&FlowVaultsScheduler.SchedulerManager>(from: self.SchedulerManagerStoragePath) {
            if manager.hasScheduled(tideID: tideID) {
                let refunded <- manager.cancelRebalancing(tideID: tideID)
                // Deposit refund to FlowVaults main vault
                let vaultRef = self.account.storage
                    .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
                    ?? panic("unregisterTide: cannot borrow FlowToken Vault for refund")
                vaultRef.deposit(from: <-refunded)
            }
        }
    }

    /// Lists registered tides
    access(all) fun getRegisteredTideIDs(): [UInt64] {
        return FlowVaultsSchedulerRegistry.getRegisteredTideIDs()
    }

    /// Estimates the cost of scheduling a rebalancing transaction
    ///
    /// @param timestamp: The desired execution timestamp
    /// @param priority: The priority level
    /// @param executionEffort: The computational effort to allocate
    /// @return An estimate containing the required fee and actual scheduled timestamp
    ///
    access(all) fun estimateSchedulingCost(
        timestamp: UFix64,
        priority: FlowTransactionScheduler.Priority,
        executionEffort: UInt64
    ): FlowTransactionScheduler.EstimatedScheduledTransaction {
        return FlowTransactionScheduler.estimate(
            data: nil,
            timestamp: timestamp,
            priority: priority,
            executionEffort: executionEffort
        )
    }

    /// Returns the scheduler configuration
    access(all) fun getSchedulerConfig(): {FlowTransactionScheduler.SchedulerConfig} {
        return FlowTransactionScheduler.getConfig()
    }

    init() {
        // Initialize paths
        let identifier = "FlowVaultsScheduler_\(self.account.address)"
        self.SchedulerManagerStoragePath = StoragePath(identifier: "\(identifier)_SchedulerManager")!
        self.SchedulerManagerPublicPath = PublicPath(identifier: "\(identifier)_SchedulerManager")!
    }
}


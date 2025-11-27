// standards
import "FungibleToken"
import "FlowToken"
// Flow system contracts
import "FlowTransactionScheduler"
// DeFiActions
import "DeFiActions"
// Registry storage (separate contract)
import "FlowVaultsSchedulerRegistry"
// AutoBalancer management (for detecting stuck tides)
import "FlowVaultsAutoBalancers"

/// FlowVaultsScheduler
///
/// This contract provides the Supervisor for recovery of stuck AutoBalancers.
///
/// Architecture:
/// - AutoBalancers are configured with recurringConfig at creation in FlowVaultsStrategies
/// - AutoBalancers self-schedule subsequent executions via their native mechanism
/// - FlowVaultsAutoBalancers handles registration with the registry and starts scheduling
/// - The Supervisor is a recovery mechanism for AutoBalancers that fail to self-schedule
///
/// Key Features:
/// - Supervisor detects stuck tides (failed to self-schedule) and seeds them
/// - Query and estimation functions for scripts
///
access(all) contract FlowVaultsScheduler {

    /* --- CONSTANTS --- */

    /// Default recurring interval in seconds (used when not specified)
    access(all) let DEFAULT_RECURRING_INTERVAL: UFix64

    /// Default priority for recurring schedules
    access(all) let DEFAULT_PRIORITY: UInt8  // 1 = Medium

    /// Default execution effort for scheduled transactions
    access(all) let DEFAULT_EXECUTION_EFFORT: UInt64

    /// Minimum fee fallback when estimation returns nil
    access(all) let MIN_FEE_FALLBACK: UFix64

    /// Fee margin multiplier to add buffer to estimated fees (1.2 = 20% buffer)
    access(all) let FEE_MARGIN_MULTIPLIER: UFix64

    /// Default lookahead seconds for scheduling first execution
    access(all) let DEFAULT_LOOKAHEAD_SECS: UFix64

    /* --- PATHS --- */

    /// Storage path for the Supervisor resource
    access(all) let SupervisorStoragePath: StoragePath

    /* --- EVENTS --- */

    /// Emitted when a rebalancing transaction is scheduled for a Tide (by Supervisor)
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

    /// Emitted when the Supervisor seeds a tide from the pending queue
    access(all) event SupervisorSeededTide(
        tideID: UInt64,
        scheduledTransactionID: UInt64,
        timestamp: UFix64
    )

    /// Emitted when Supervisor detects a stuck tide via state-based scanning
    access(all) event StuckTideDetected(
        tideID: UInt64
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

    /// Supervisor - The recovery mechanism for stuck AutoBalancers
    ///
    /// The Supervisor:
    /// - Detects stuck tides (AutoBalancers that failed to self-schedule)
    /// - Seeds stuck tides by scheduling a recovery execution
    /// - Tracks recovery schedules it has created
    /// - Can self-reschedule for perpetual operation
    ///
    /// Primary scheduling is done by AutoBalancers themselves via their native recurringConfig.
    /// The Supervisor is only for recovery when that fails.
    ///
    access(all) resource Supervisor: FlowTransactionScheduler.TransactionHandler {
        /// Maps Tide IDs to their scheduled transaction resources (recovery schedules)
        access(self) let scheduledTransactions: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}
        /// Maps scheduled transaction IDs to rebalancing schedule data
        access(self) let scheduleData: {UInt64: RebalancingScheduleData}
        /// Capability to withdraw FLOW for scheduling fees
        access(self) let feesCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>

        init(
            feesCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
        ) {
            self.scheduledTransactions <- {}
            self.scheduleData = {}
            self.feesCap = feesCap
        }

        /* --- SCHEDULING METHODS --- */

        /// Schedules a recovery rebalancing transaction for a specific Tide
        ///
        /// @param handlerCap: A capability to the AutoBalancer that implements TransactionHandler
        /// @param tideID: The ID of the Tide to schedule rebalancing for
        /// @param timestamp: The Unix timestamp when the rebalancing should occur
        /// @param priority: The priority level (High, Medium, or Low)
        /// @param executionEffort: The computational effort allocated for execution
        /// @param fees: Flow tokens to pay for the scheduled transaction
        /// @param force: Whether to force rebalancing regardless of thresholds
        ///
        access(self) fun scheduleRecovery(
            handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
            tideID: UInt64,
            timestamp: UFix64,
            priority: FlowTransactionScheduler.Priority,
            executionEffort: UInt64,
            fees: @FlowToken.Vault,
            force: Bool
        ): UInt64 {
            // Cleanup any executed/removed entry for this tideID
            let existingRef = &self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction?
            if existingRef != nil {
                let existingTxID = existingRef!.id
                let st = FlowTransactionScheduler.getStatus(id: existingTxID)
                if st == nil || st == FlowTransactionScheduler.Status.Executed {
                    let old <- self.scheduledTransactions.remove(key: tideID)
                        ?? panic("scheduleRecovery: cleanup remove failed")
                    destroy old
                    let _ = self.scheduleData.remove(key: existingTxID)
                }
            }

            // Validate not already scheduled
            if (&self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction?) != nil {
                panic("Recovery already scheduled for Tide #".concat(tideID.toString()))
            }

            if !handlerCap.check() {
                panic("Invalid handler capability provided")
            }

            // Schedule with restartRecurring: true so AutoBalancer resumes self-scheduling
            let data: {String: AnyStruct} = {
                "force": force,
                "restartRecurring": true
            }
            let scheduledTx <- FlowTransactionScheduler.schedule(
                handlerCap: handlerCap,
                data: data,
                timestamp: timestamp,
                priority: priority,
                executionEffort: executionEffort,
                fees: <-fees
            )

            let txID = scheduledTx.id

            // Store the schedule information
            let scheduleInfo = RebalancingScheduleData(
                tideID: tideID,
                isRecurring: true,
                recurringInterval: FlowVaultsScheduler.DEFAULT_RECURRING_INTERVAL,
                force: force
            )
            self.scheduleData[txID] = scheduleInfo

            emit RebalancingScheduled(
                tideID: tideID,
                scheduledTransactionID: txID,
                timestamp: timestamp,
                priority: priority.rawValue,
                isRecurring: true,
                recurringInterval: FlowVaultsScheduler.DEFAULT_RECURRING_INTERVAL,
                force: force
            )

            // Store the scheduled transaction
            self.scheduledTransactions[tideID] <-! scheduledTx

            return txID
        }

        /// Cancels a scheduled recovery transaction for a specific Tide
        /// RESTRICTED: Only callable by the contract account to prevent external interference
        ///
        /// @param tideID: The ID of the Tide whose scheduled rebalancing should be canceled
        /// @return The refunded fees
        ///
        access(account) fun cancelRecovery(tideID: UInt64): @FlowToken.Vault {
            pre {
                self.scheduledTransactions[tideID] != nil:
                    "No recovery scheduled for Tide #\(tideID)"
            }

            let scheduledTx <- self.scheduledTransactions.remove(key: tideID)
                ?? panic("Could not remove scheduled transaction for Tide #\(tideID)")

            let txID = scheduledTx.id

            let status = FlowTransactionScheduler.getStatus(id: txID)
            if status == nil || status == FlowTransactionScheduler.Status.Executed {
                destroy scheduledTx
                let _removed = self.scheduleData.remove(key: txID)
                emit RebalancingCanceled(
                    tideID: tideID,
                    scheduledTransactionID: txID,
                    feesReturned: 0.0
                )
                return <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
            }

            let refund <- FlowTransactionScheduler.cancel(scheduledTx: <-scheduledTx)
            let _removed = self.scheduleData.remove(key: txID)

            emit RebalancingCanceled(
                tideID: tideID,
                scheduledTransactionID: txID,
                feesReturned: refund.balance
            )

            return <-refund
        }

        /* --- QUERY METHODS --- */

        /// Returns true if a Tide currently has a recovery schedule
        access(all) fun hasScheduled(tideID: UInt64): Bool {
            let txRef = &self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction?
            if txRef == nil {
                return false
            }
            let status = FlowTransactionScheduler.getStatus(id: txRef!.id)
            if status == nil || status == FlowTransactionScheduler.Status.Executed {
                return false
            }
            return true
        }

        /// Returns information about a scheduled recovery for a specific Tide
        access(all) fun getScheduledRecovery(tideID: UInt64): RebalancingScheduleInfo? {
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

        /// Returns the Tide IDs that have recovery schedules
        access(all) view fun getScheduledTideIDs(): [UInt64] {
            return self.scheduledTransactions.keys
        }

        /// Manually enqueues a registered tide to the pending queue for recovery.
        /// RESTRICTED: Only callable by the contract account.
        ///
        /// @param tideID: The ID of the registered tide to enqueue
        ///
        access(account) fun enqueuePendingTide(tideID: UInt64) {
            assert(
                FlowVaultsSchedulerRegistry.isRegistered(tideID: tideID),
                message: "enqueuePendingTide: Tide #".concat(tideID.toString()).concat(" is not registered")
            )
            FlowVaultsSchedulerRegistry.enqueuePending(tideID: tideID)
        }

        /* --- TRANSACTION HANDLER --- */

        /// Processes pending tides from the queue (bounded by MAX_BATCH_SIZE)
        /// Also detects stuck tides (tides that failed to self-reschedule) and adds them to pending.
        ///
        /// Detection methods:
        /// 1. Event-based: FailedRecurringSchedule events are emitted by AutoBalancer
        /// 2. State-based: Scans for registered tides with no active schedule (catches panics)
        ///
        /// data accepts optional config:
        /// {
        ///   "priority": UInt8 (0=High,1=Medium,2=Low),
        ///   "executionEffort": UInt64,
        ///   "lookaheadSecs": UFix64,
        ///   "force": Bool,
        ///   "recurringInterval": UFix64 (for Supervisor self-rescheduling),
        ///   "scanForStuck": Bool (default true - scan all registered tides for stuck ones)
        /// }
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let cfg = data as? {String: AnyStruct} ?? {}
            let priorityRaw = cfg["priority"] as? UInt8 ?? FlowVaultsScheduler.DEFAULT_PRIORITY
            let executionEffort = cfg["executionEffort"] as? UInt64 ?? FlowVaultsScheduler.DEFAULT_EXECUTION_EFFORT
            let lookaheadSecs = cfg["lookaheadSecs"] as? UFix64 ?? FlowVaultsScheduler.DEFAULT_LOOKAHEAD_SECS
            let forceChild = cfg["force"] as? Bool ?? false
            let recurringInterval = cfg["recurringInterval"] as? UFix64
            let scanForStuck = cfg["scanForStuck"] as? Bool ?? true

            let priority = FlowTransactionScheduler.Priority(rawValue: priorityRaw)
                ?? FlowTransactionScheduler.Priority.Medium

            // STEP 1: State-based detection - scan for stuck tides
            if scanForStuck {
                let registeredTides = FlowVaultsSchedulerRegistry.getRegisteredTideIDs()
                var scanned = 0
                for tideID in registeredTides {
                    if scanned >= FlowVaultsSchedulerRegistry.MAX_BATCH_SIZE {
                        break
                    }
                    scanned = scanned + 1
                    
                    if FlowVaultsSchedulerRegistry.getPendingTideIDs().contains(tideID) {
                        continue
                    }
                    
                    if FlowVaultsAutoBalancers.isStuckTide(id: tideID) {
                        FlowVaultsSchedulerRegistry.enqueuePending(tideID: tideID)
                        emit StuckTideDetected(tideID: tideID)
                    }
                }
            }

            // STEP 2: Process pending tides (first page, bounded by MAX_BATCH_SIZE)
            let pendingTides = FlowVaultsSchedulerRegistry.getPendingTideIDsPaginated(page: 0, size: nil)
            
            for tideID in pendingTides {
                // Skip if already has a recovery schedule
                if self.hasScheduled(tideID: tideID) {
                    FlowVaultsSchedulerRegistry.dequeuePending(tideID: tideID)
                    continue
                }

                // Get handler capability (AutoBalancer) for this tide
                let handlerCap = FlowVaultsSchedulerRegistry.getHandlerCap(tideID: tideID)
                if handlerCap == nil || !handlerCap!.check() {
                    continue
                }

                // Estimate fee with margin buffer and schedule
                let ts = getCurrentBlock().timestamp + lookaheadSecs
                let est = FlowVaultsScheduler.estimateSchedulingCost(
                    timestamp: ts,
                    priority: priority,
                    executionEffort: executionEffort
                )
                let baseFee = est.flowFee ?? FlowVaultsScheduler.MIN_FEE_FALLBACK
                let required = baseFee * FlowVaultsScheduler.FEE_MARGIN_MULTIPLIER
                let vaultRef = self.feesCap.borrow()
                    ?? panic("Supervisor: cannot borrow FlowToken Vault")
                let pay <- vaultRef.withdraw(amount: required) as! @FlowToken.Vault

                let txID = self.scheduleRecovery(
                    handlerCap: handlerCap!,
                    tideID: tideID,
                    timestamp: ts,
                    priority: priority,
                    executionEffort: executionEffort,
                    fees: <-pay,
                    force: forceChild
                )

                FlowVaultsSchedulerRegistry.dequeuePending(tideID: tideID)

                emit SupervisorSeededTide(
                    tideID: tideID,
                    scheduledTransactionID: txID,
                    timestamp: ts
                )
            }

            // Self-reschedule for perpetual operation if configured and there are still pending tides
            if let interval = recurringInterval {
                if FlowVaultsSchedulerRegistry.getPendingCount() > 0 {
                    let nextTimestamp = getCurrentBlock().timestamp + interval
                    let est = FlowVaultsScheduler.estimateSchedulingCost(
                        timestamp: nextTimestamp,
                        priority: priority,
                        executionEffort: executionEffort
                    )
                    let baseFee = est.flowFee ?? FlowVaultsScheduler.MIN_FEE_FALLBACK
                    let required = baseFee * FlowVaultsScheduler.FEE_MARGIN_MULTIPLIER
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
    }

    /* --- PRIVATE FUNCTIONS (access(self)) --- */

    /// Creates a Supervisor handler.
    access(self) fun createSupervisor(): @Supervisor {
        let feesCap = self.account.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
        return <- create Supervisor(feesCap: feesCap)
    }

    /* --- PUBLIC FUNCTIONS (access(all)) --- */

    /// Returns the Supervisor capability for scheduling
    access(all) view fun getSupervisorCap(): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return FlowVaultsSchedulerRegistry.getSupervisorCap()
    }

    /// Borrows a reference to the Supervisor for internal operations
    /// RESTRICTED: Only callable by the contract account to prevent external access
    access(account) fun borrowSupervisor(): &Supervisor? {
        return self.account.storage.borrow<&Supervisor>(from: self.SupervisorStoragePath)
    }

    /// Ensures that the global Supervisor exists and is registered.
    /// Idempotent - safe to call multiple times.
    access(all) fun ensureSupervisorConfigured() {
        if self.account.storage.borrow<&Supervisor>(from: self.SupervisorStoragePath) == nil {
            let sup <- self.createSupervisor()
            self.account.storage.save(<-sup, to: self.SupervisorStoragePath)
            
            let supCap = self.account.capabilities.storage
                .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(self.SupervisorStoragePath)
            FlowVaultsSchedulerRegistry.setSupervisorCap(cap: supCap)
        }
    }

    /* --- ACCOUNT FUNCTIONS (access(account)) --- */

    /// Lists registered tides
    access(all) fun getRegisteredTideIDs(): [UInt64] {
        return FlowVaultsSchedulerRegistry.getRegisteredTideIDs()
    }

    /// Estimates the cost of scheduling a rebalancing transaction
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

    /// Returns the scheduler configuration from FlowTransactionScheduler.
    access(all) fun getSchedulerConfig(): {FlowTransactionScheduler.SchedulerConfig} {
        return FlowTransactionScheduler.getConfig()
    }

    init() {
        // Initialize constants
        self.DEFAULT_RECURRING_INTERVAL = 60.0
        self.DEFAULT_PRIORITY = 1
        self.DEFAULT_EXECUTION_EFFORT = 800
        self.MIN_FEE_FALLBACK = 0.00005
        self.FEE_MARGIN_MULTIPLIER = 1.2
        self.DEFAULT_LOOKAHEAD_SECS = 5.0

        // Initialize path
        let identifier = "FlowVaultsScheduler_\(self.account.address)"
        self.SupervisorStoragePath = StoragePath(identifier: "\(identifier)_Supervisor")!
        
        // Ensure Supervisor is configured
        self.ensureSupervisorConfigured()
    }
}

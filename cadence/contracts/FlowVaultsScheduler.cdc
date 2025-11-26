// standards
import "FungibleToken"
import "FlowToken"
// Flow system contracts
import "FlowTransactionScheduler"
// DeFiActions
import "DeFiActions"
// Registry storage (separate contract)
import "FlowVaultsSchedulerRegistry"
// NOTE: FlowVaultsAutoBalancers is NOT imported here to avoid circular dependency.
// FlowVaultsAutoBalancers imports FlowVaultsScheduler for registration.

/// FlowVaultsScheduler
///
/// This contract enables the scheduling of autonomous rebalancing transactions for FlowVaults Tides.
/// It integrates with Flow's FlowTransactionScheduler to schedule periodic rebalancing operations
/// on AutoBalancers associated with specific Tide IDs.
///
/// Architecture:
/// - AutoBalancers implement FlowTransactionScheduler.TransactionHandler directly
/// - When configured with a recurringConfig, AutoBalancers self-schedule subsequent executions
/// - Initial scheduling happens atomically at tide registration
/// - The Supervisor only handles failure recovery for tides that failed to schedule
///
/// Key Features:
/// - Atomic initial scheduling at tide creation
/// - AutoBalancer-native recurring scheduling (no wrapper needed)
/// - Paginated Supervisor for failure recovery only
/// - Cancel and query scheduled transactions
/// - Estimate scheduling costs before committing funds
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

    /// Emitted when a tide is registered and initial scheduling succeeds
    /// Note: If scheduling fails, the transaction reverts - no partial success
    access(all) event TideRegistered(
        tideID: UInt64,
        scheduledTransactionID: UInt64
    )

    /// Emitted when the Supervisor seeds a tide from the pending queue
    access(all) event SupervisorSeededTide(
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

    // NOTE: RebalancingHandler wrapper has been removed.
    // AutoBalancers now implement FlowTransactionScheduler.TransactionHandler directly
    // and handle their own recurring scheduling via their native recurringConfig.

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
                let existingTxID = existingRef!.id
                let st = FlowTransactionScheduler.getStatus(id: existingTxID)
                if st == nil || st!.rawValue == 2 {
                    let old <- self.scheduledTransactions.remove(key: tideID)
                        ?? panic("scheduleRebalancing: cleanup remove failed")
                    destroy old
                    // Also clean up the associated scheduleData
                    let _ = self.scheduleData.remove(key: existingTxID)
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

            // Check if the transaction is still active/cancellable
            // Status nil = no longer exists, rawValue 2 = already executed
            let status = FlowTransactionScheduler.getStatus(id: txID)
            if status == nil || status!.rawValue == 2 {
                // Transaction already executed or no longer exists - clean up locally
                destroy scheduledTx
                let _removed = self.scheduleData.remove(key: txID)
                emit RebalancingCanceled(
                    tideID: tideID,
                    scheduledTransactionID: txID,
                    feesReturned: 0.0
                )
                // Return an empty vault since there's nothing to refund
                return <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
            }

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

        /// Removes schedule data for a completed scheduled transaction ID.
        /// This should be called after a recurring schedule has been processed
        /// to prevent unbounded growth of the scheduleData dictionary.
        access(all) fun removeScheduleData(id: UInt64) {
            let _ = self.scheduleData.remove(key: id)
        }

        /// Manually enqueues a registered tide to the pending queue for Supervisor recovery.
        /// This is used when monitoring detects that a tide's AutoBalancer failed to self-reschedule.
        ///
        /// @param tideID: The ID of the registered tide to enqueue
        ///
        access(all) fun enqueuePendingTide(tideID: UInt64) {
            // Verify tide is registered
            assert(
                FlowVaultsSchedulerRegistry.isRegistered(tideID: tideID),
                message: "enqueuePendingTide: Tide #".concat(tideID.toString()).concat(" is not registered")
            )
            FlowVaultsSchedulerRegistry.enqueuePending(tideID: tideID)
        }
    }

    /// Supervisor - A recovery handler that seeds tides from the pending queue
    ///
    /// The Supervisor now operates on a bounded pending queue instead of iterating all tides.
    /// It only processes tides that:
    /// - Failed initial scheduling at registration
    /// - Had their schedules expire or fail
    ///
    /// This is a recovery mechanism, not the primary scheduling path.
    /// Primary scheduling happens atomically at tide registration.
    ///
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

        /// Processes pending tides from the queue (bounded by MAX_BATCH_SIZE)
        ///
        /// data accepts optional config:
        /// {
        ///   "priority": UInt8 (0=High,1=Medium,2=Low),
        ///   "executionEffort": UInt64,
        ///   "lookaheadSecs": UFix64,
        ///   "force": Bool,
        ///   "recurringInterval": UFix64 (for Supervisor self-rescheduling)
        /// }
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let cfg = data as? {String: AnyStruct} ?? {}
            let priorityRaw = cfg["priority"] as? UInt8 ?? FlowVaultsScheduler.DEFAULT_PRIORITY
            let executionEffort = cfg["executionEffort"] as? UInt64 ?? FlowVaultsScheduler.DEFAULT_EXECUTION_EFFORT
            let lookaheadSecs = cfg["lookaheadSecs"] as? UFix64 ?? FlowVaultsScheduler.DEFAULT_LOOKAHEAD_SECS
            let forceChild = cfg["force"] as? Bool ?? false
            let recurringInterval = cfg["recurringInterval"] as? UFix64

            let priority = FlowTransactionScheduler.Priority(rawValue: priorityRaw)
                ?? FlowTransactionScheduler.Priority.Medium

            let manager = self.managerCap.borrow()
                ?? panic("Supervisor: missing SchedulerManager")

            // Process only pending tides (bounded by MAX_BATCH_SIZE in the registry)
            let pendingTides = FlowVaultsSchedulerRegistry.getPendingTideIDs()
            
            for tideID in pendingTides {
                // Skip if already scheduled (may have been scheduled between queue add and now)
                if manager.hasScheduled(tideID: tideID) {
                    FlowVaultsSchedulerRegistry.dequeuePending(tideID: tideID)
                    continue
                }

                // Get handler capability (AutoBalancer) for this tide
                let handlerCap = FlowVaultsSchedulerRegistry.getHandlerCap(tideID: tideID)
                if handlerCap == nil || !handlerCap!.check() {
                    // Invalid capability - skip but leave in queue for later retry or manual intervention
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

                manager.scheduleRebalancing(
                    handlerCap: handlerCap!,
                    tideID: tideID,
                    timestamp: ts,
                    priority: priority,
                    executionEffort: executionEffort,
                    fees: <-pay,
                    force: forceChild,
                    isRecurring: true,  // AutoBalancer will handle recurrence natively
                    recurringInterval: FlowVaultsScheduler.DEFAULT_RECURRING_INTERVAL
                )

                // Remove from pending queue after successful scheduling
                FlowVaultsSchedulerRegistry.dequeuePending(tideID: tideID)

                emit SupervisorSeededTide(
                    tideID: tideID,
                    scheduledTransactionID: manager.getScheduledRebalancing(tideID: tideID)?.scheduledTransactionID ?? 0,
                    timestamp: ts
                )
            }

            // Self-reschedule for perpetual operation if configured and there are still pending tides
            if let interval = recurringInterval {
                // Only reschedule if there's more work to do
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

    // NOTE: scheduleNextIfRecurring has been removed.
    // AutoBalancers now handle their own recurring scheduling via their native recurringConfig.
    // When an AutoBalancer's executeTransaction completes, it automatically schedules the next
    // execution if recurringConfig is set.

    /* --- PRIVATE FUNCTIONS (access(self)) --- */

    /// Creates a Supervisor handler.
    /// Restricted to prevent arbitrary minting of Supervisor instances.
    access(self) fun createSupervisor(): @Supervisor {
        let mgrCap = self.account.capabilities.storage
            .issue<&FlowVaultsScheduler.SchedulerManager>(self.SchedulerManagerStoragePath)
        let feesCap = self.account.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
        return <- create Supervisor(managerCap: mgrCap, feesCap: feesCap)
    }

    /// Storage path for the single global Supervisor
    access(self) let SupervisorStoragePath: StoragePath

    /* --- PUBLIC FUNCTIONS (access(all)) --- */

    /// Returns the Supervisor capability for scheduling
    /// This function bridges public access to the account-level registry function
    access(all) view fun getSupervisorCap(): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return FlowVaultsSchedulerRegistry.getSupervisorCap()
    }

    /// Ensures that the global Supervisor exists and is registered.
    /// Idempotent - safe to call multiple times.
    access(all) fun ensureSupervisorConfigured() {
        // Create and store the Supervisor resource if it does not yet exist.
        if self.account.storage.borrow<&FlowVaultsScheduler.Supervisor>(from: self.SupervisorStoragePath) == nil {
            let sup <- self.createSupervisor()
            self.account.storage.save(<-sup, to: self.SupervisorStoragePath)
            
            // Only issue capability on first creation
            let supCap = self.account.capabilities.storage
                .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(self.SupervisorStoragePath)
            FlowVaultsSchedulerRegistry.setSupervisorCap(cap: supCap)
        }
    }

    /// Creates a new SchedulerManager resource
    access(all) fun createSchedulerManager(): @SchedulerManager {
        return <- create SchedulerManager()
    }

    /* --- ACCOUNT FUNCTIONS (access(account)) --- */

    /// Registers a tide and schedules its first rebalancing atomically
    ///
    /// This function:
    /// 1. Issues a capability directly to the AutoBalancer (no wrapper)
    /// 2. Registers the tide in the registry
    /// 3. Schedules the first execution atomically
    ///
    /// If scheduling fails for any reason, the entire operation panics and reverts.
    /// This ensures tide creation is atomic with its first scheduled rebalancing.
    ///
    access(account) fun registerTide(tideID: UInt64) {
        // Check if already registered with a valid capability - skip if so
        if let existingCap = FlowVaultsSchedulerRegistry.getHandlerCap(tideID: tideID) {
            if existingCap.check() {
                return // Already registered with valid capability
            }
        }
        
        // Issue capability directly to AutoBalancer (no wrapper needed)
        // Path matches FlowVaultsAutoBalancers.deriveAutoBalancerPath - kept in sync manually
        // to avoid circular import (FlowVaultsAutoBalancers imports FlowVaultsScheduler)
        let abPath = StoragePath(identifier: "FlowVaultsAutoBalancer_".concat(tideID.toString()))!
        let handlerCap = self.account.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(abPath)
        
        // Verify the capability is valid before proceeding
        assert(handlerCap.check(), message: "registerTide: Failed to issue valid capability for AutoBalancer of Tide #".concat(tideID.toString()))
        
        // Register tide with its AutoBalancer capability
        FlowVaultsSchedulerRegistry.register(tideID: tideID, handlerCap: handlerCap)
        
        // Borrow the SchedulerManager - must exist for atomic scheduling
        let manager = self.account.storage.borrow<&FlowVaultsScheduler.SchedulerManager>(from: self.SchedulerManagerStoragePath)
            ?? panic("registerTide: SchedulerManager not found. Ensure contract is properly initialized.")
        
        // If already scheduled (shouldn't happen for new tides, but handle gracefully)
        if manager.hasScheduled(tideID: tideID) {
            let existingTxID = manager.getScheduledRebalancing(tideID: tideID)?.scheduledTransactionID ?? 0
            emit TideRegistered(
                tideID: tideID,
                scheduledTransactionID: existingTxID
            )
            return
        }
        
        // Calculate scheduling parameters
        let ts = getCurrentBlock().timestamp + self.DEFAULT_LOOKAHEAD_SECS
        let priority = FlowTransactionScheduler.Priority.Medium
        let executionEffort = self.DEFAULT_EXECUTION_EFFORT
        
        // Estimate fee with margin buffer
        let est = self.estimateSchedulingCost(
            timestamp: ts,
            priority: priority,
            executionEffort: executionEffort
        )
        let baseFee = est.flowFee ?? self.MIN_FEE_FALLBACK
        let required = baseFee * self.FEE_MARGIN_MULTIPLIER
        
        // Borrow FlowToken vault - must have sufficient balance
        let vaultRef = self.account.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("registerTide: FlowToken vault not found at /storage/flowTokenVault")
        
        assert(
            vaultRef.balance >= required,
            message: "registerTide: Insufficient FLOW balance for scheduling. Required: ".concat(required.toString()).concat(", Available: ").concat(vaultRef.balance.toString())
        )
        
        // Withdraw fees and schedule
        let pay <- vaultRef.withdraw(amount: required) as! @FlowToken.Vault
        
        manager.scheduleRebalancing(
            handlerCap: handlerCap,
            tideID: tideID,
            timestamp: ts,
            priority: priority,
            executionEffort: executionEffort,
            fees: <-pay,
            force: false,
            isRecurring: true,
            recurringInterval: self.DEFAULT_RECURRING_INTERVAL
        )
        
        let scheduledTxID = manager.getScheduledRebalancing(tideID: tideID)?.scheduledTransactionID ?? 0
        
        emit TideRegistered(
            tideID: tideID,
            scheduledTransactionID: scheduledTxID
        )
    }

    /// Unregisters a tide (idempotent) and cleans up pending schedules
    access(account) fun unregisterTide(tideID: UInt64) {
        // 1. Unregister from registry (also removes from pending queue)
        FlowVaultsSchedulerRegistry.unregister(tideID: tideID)
        
        // 2. Cancel any pending rebalancing in SchedulerManager
        if let manager = self.account.storage.borrow<&FlowVaultsScheduler.SchedulerManager>(from: self.SchedulerManagerStoragePath) {
            if manager.hasScheduled(tideID: tideID) {
                let refunded <- manager.cancelRebalancing(tideID: tideID)
                // Deposit refund to FlowVaults main vault (using non-auth reference for deposit)
                let vaultRef = self.account.storage
                    .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
                    ?? panic("unregisterTide: cannot borrow FlowToken Vault for refund")
                vaultRef.deposit(from: <-refunded)
            }
        }
        
        // NOTE: No wrapper to destroy - AutoBalancers are cleaned up when the Strategy is burned
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

    /// Returns the scheduler configuration from FlowTransactionScheduler.
    /// Convenience wrapper for scripts to access scheduler config through FlowVaultsScheduler.
    access(all) fun getSchedulerConfig(): {FlowTransactionScheduler.SchedulerConfig} {
        return FlowTransactionScheduler.getConfig()
    }

    init() {
        // Initialize constants
        self.DEFAULT_RECURRING_INTERVAL = 60.0       // 60 seconds
        self.DEFAULT_PRIORITY = 1                     // Medium priority
        self.DEFAULT_EXECUTION_EFFORT = 800           // Standard effort
        self.MIN_FEE_FALLBACK = 0.00005              // Minimum fee if estimation fails
        self.FEE_MARGIN_MULTIPLIER = 1.2             // 20% buffer on estimated fees
        self.DEFAULT_LOOKAHEAD_SECS = 5.0            // Schedule first execution 5 seconds from now

        // Initialize paths
        let identifier = "FlowVaultsScheduler_\(self.account.address)"
        self.SchedulerManagerStoragePath = StoragePath(identifier: "\(identifier)_SchedulerManager")!
        self.SchedulerManagerPublicPath = PublicPath(identifier: "\(identifier)_SchedulerManager")!
        self.SupervisorStoragePath = StoragePath(identifier: "\(identifier)_Supervisor")!
        
        // Ensure SchedulerManager exists in storage for atomic scheduling at registration
        if self.account.storage.borrow<&SchedulerManager>(from: self.SchedulerManagerStoragePath) == nil {
            self.account.storage.save(<-create SchedulerManager(), to: self.SchedulerManagerStoragePath)
            let cap = self.account.capabilities.storage
                .issue<&SchedulerManager>(self.SchedulerManagerStoragePath)
            self.account.capabilities.publish(cap, at: self.SchedulerManagerPublicPath)
        }
        
        // Ensure Supervisor is configured
        self.ensureSupervisorConfigured()
    }
}


// standards
import "FungibleToken"
import "FlowToken"
// Flow system contracts
import "FlowTransactionScheduler"
// DeFiActions
import "DeFiActions"
// Registry storage (separate contract)
import "FlowYieldVaultsSchedulerRegistry"
// AutoBalancer management (for detecting stuck yield vaults)
import "FlowYieldVaultsAutoBalancers"

/// FlowYieldVaultsScheduler
///
/// This contract provides the Supervisor for recovery of stuck AutoBalancers.
///
/// Architecture:
/// - AutoBalancers are configured with recurringConfig at creation in FlowYieldVaultsStrategies
/// - AutoBalancers self-schedule subsequent executions via their native mechanism
/// - FlowYieldVaultsAutoBalancers handles registration with the registry and starts scheduling
/// - The Supervisor is a recovery mechanism for AutoBalancers that fail to self-schedule
///
/// Key Features:
/// - Supervisor detects stuck yield vaults (failed to self-schedule) and recovers them
/// - Uses Schedule capability to directly call AutoBalancer.scheduleNextRebalance()
/// - Query and estimation functions for scripts
///
access(all) contract FlowYieldVaultsSchedulerV1 {

    /* --- FIELDS --- */

    /// Default recurring interval in seconds (used when not specified)
    access(all) var DEFAULT_RECURRING_INTERVAL: UFix64

    /// Default priority for recurring schedules
    access(all) var DEFAULT_PRIORITY: UInt8  // 1 = Medium

    /// Default execution effort for scheduled transactions
    access(all) var DEFAULT_EXECUTION_EFFORT: UInt64

    /// Minimum fee fallback when estimation returns nil
    access(all) var MIN_FEE_FALLBACK: UFix64

    /// Fee margin multiplier to add buffer to estimated fees (1.2 = 20% buffer)
    access(all) var FEE_MARGIN_MULTIPLIER: UFix64

    /* --- PATHS --- */

    /// Storage path for the Supervisor resource
    access(all) let SupervisorStoragePath: StoragePath

    /* --- EVENTS --- */

    /// Emitted when the Supervisor successfully recovers a stuck yield vault
    access(all) event YieldVaultRecovered(
        yieldVaultID: UInt64
    )

    /// Emitted when Supervisor fails to recover a yield vault
    access(all) event YieldVaultRecoveryFailed(
        yieldVaultID: UInt64,
        error: String
    )

    /// Emitted when Supervisor detects a stuck yield vault via state-based scanning
    access(all) event StuckYieldVaultDetected(
        yieldVaultID: UInt64
    )

    /// Emitted when Supervisor self-reschedules
    access(all) event SupervisorRescheduled(
        scheduledTransactionID: UInt64,
        timestamp: UFix64
    )

    /// Entitlement to schedule transactions
    access(all) entitlement Schedule

    /* --- RESOURCES --- */

    access(all) entitlement Configure

    /// Supervisor - The recovery mechanism for stuck AutoBalancers
    ///
    /// The Supervisor:
    /// - Detects stuck yield vaults (AutoBalancers that failed to self-schedule)
    /// - Recovers stuck yield vaults by directly calling scheduleNextRebalance() via Schedule capability
    /// - Can self-reschedule for perpetual operation
    ///
    /// Primary scheduling is done by AutoBalancers themselves via their native recurringConfig.
    /// The Supervisor is only for recovery when that fails.
    ///
    access(all) resource Supervisor: FlowTransactionScheduler.TransactionHandler {
        /// Capability to withdraw FLOW for Supervisor's own scheduling fees
        access(self) let feesCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
        /// Internally managed scheduled transaction for Supervisor self-rescheduling
        access(self) var _scheduledTransaction: @FlowTransactionScheduler.ScheduledTransaction?

        init(
            feesCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
        ) {
            self.feesCap = feesCap
            self._scheduledTransaction <- nil
        }

        /// Returns the ID of the internally managed scheduled transaction, or nil if not scheduled
        ///
        /// @return UInt64?: The ID of the internally managed scheduled transaction, or nil if not scheduled
        access(all) view fun getScheduledTransactionID(): UInt64? {
            return self._scheduledTransaction?.id
        }

        /* --- CONFIGURE FUNCTIONS --- */

        /// Sets the default recurring interval for Supervisor self-rescheduling
        /// @param interval: The interval to set
        access(Configure) fun setDefaultRecurringInterval(_ interval: UFix64) {
            FlowYieldVaultsSchedulerV1.DEFAULT_RECURRING_INTERVAL = interval
        }

        /// Sets the default execution effort for Supervisor self-rescheduling
        /// @param effort: The execution effort to set
        access(Configure) fun setDefaultExecutionEffort(_ effort: UInt64) {
            FlowYieldVaultsSchedulerV1.DEFAULT_EXECUTION_EFFORT = effort
        }

        /// Sets the default minimum fee fallback for Supervisor self-rescheduling
        /// @param fallback: The minimum fee fallback to set
        access(Configure) fun setDefaultMinFeeFallback(_ fallback: UFix64) {
            FlowYieldVaultsSchedulerV1.MIN_FEE_FALLBACK = fallback
        }

        /// Sets the default fee margin multiplier for Supervisor self-rescheduling
        /// TODO: Determine if this field is even necessary
        /// @param marginMultiplier: The margin multiplier to set
        access(Configure) fun setDefaultFeeMarginMultiplier(_ marginMultiplier: UFix64) {
            FlowYieldVaultsSchedulerV1.FEE_MARGIN_MULTIPLIER = marginMultiplier
        }

        /// Sets the default priority for Supervisor self-rescheduling
        ///
        /// @param priority: The priority to set
        access(Configure) fun setDefaultPriority(_ priority: FlowTransactionScheduler.Priority) {
            FlowYieldVaultsSchedulerV1.DEFAULT_PRIORITY = priority.rawValue
        }

        /* --- TRANSACTION HANDLER --- */

        /// Detects and recovers stuck yield vaults by directly calling their scheduleNextRebalance().
        ///
        /// Detection methods:
        /// 1. State-based: Scans for registered yield vaults with no active schedule that are overdue
        ///
        /// Recovery method:
        /// - Uses Schedule capability to call AutoBalancer.scheduleNextRebalance() directly
        /// - The AutoBalancer schedules itself using its own fee source
        /// - This is simpler than the previous approach of Supervisor scheduling on behalf of AutoBalancer
        ///
        /// data accepts optional config:
        /// {
        ///   "priority": UInt8 (0=High,1=Medium,2=Low) - for Supervisor self-rescheduling
        ///   "executionEffort": UInt64 - for Supervisor self-rescheduling
        ///   "recurringInterval": UFix64 (for Supervisor self-rescheduling)
        ///   "scanForStuck": Bool (default true - scan all registered yield vaults for stuck ones)
        /// }
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let cfg = data as? {String: AnyStruct} ?? {}
            let priorityRaw = cfg["priority"] as? UInt8 ?? FlowYieldVaultsSchedulerV1.DEFAULT_PRIORITY
            let executionEffort = cfg["executionEffort"] as? UInt64 ?? FlowYieldVaultsSchedulerV1.DEFAULT_EXECUTION_EFFORT
            let recurringInterval = cfg["recurringInterval"] as? UFix64
            let scanForStuck = cfg["scanForStuck"] as? Bool ?? true

            let priority = FlowTransactionScheduler.Priority(rawValue: priorityRaw)
                ?? FlowTransactionScheduler.Priority.Medium

            // STEP 1: State-based detection - scan for stuck yield vaults
            if scanForStuck {
                // TODO: add pagination - this will inevitably fails and at minimum creates inconsistent execution
                //      effort between runs
                let registeredYieldVaults = FlowYieldVaultsSchedulerRegistry.getRegisteredYieldVaultIDs()
                var scanned = 0
                for yieldVaultID in registeredYieldVaults {
                    if scanned >= FlowYieldVaultsSchedulerRegistry.MAX_BATCH_SIZE {
                        break
                    }
                    scanned = scanned + 1
                    
                    // Skip if already in pending queue
                    if FlowYieldVaultsSchedulerRegistry.isPending(yieldVaultID: yieldVaultID) {
                        continue
                    }

                    // Check if yield vault is stuck (has recurring config, no active schedule, overdue)
                    if FlowYieldVaultsAutoBalancers.isStuckYieldVault(id: yieldVaultID) {
                        FlowYieldVaultsSchedulerRegistry.enqueuePending(yieldVaultID: yieldVaultID)
                        emit StuckYieldVaultDetected(yieldVaultID: yieldVaultID)
                    }
                }
            }

            // STEP 2: Process pending yield vaults - recover them via Schedule capability
            let pendingYieldVaults = FlowYieldVaultsSchedulerRegistry.getPendingYieldVaultIDsPaginated(page: 0, size: nil)
            
            for yieldVaultID in pendingYieldVaults {
                // Get Schedule capability for this yield vault
                let scheduleCap = FlowYieldVaultsSchedulerRegistry.getScheduleCap(yieldVaultID: yieldVaultID)
                if scheduleCap == nil || !scheduleCap!.check() {
                    emit YieldVaultRecoveryFailed(yieldVaultID: yieldVaultID, error: "Invalid Schedule capability")
                    continue
                }

                // Borrow the AutoBalancer and call scheduleNextRebalance() directly
                let autoBalancerRef = scheduleCap!.borrow()!
                let scheduleError = autoBalancerRef.scheduleNextRebalance(whileExecuting: nil)

                if scheduleError != nil {
                    emit YieldVaultRecoveryFailed(yieldVaultID: yieldVaultID, error: scheduleError!)
                    // Leave in pending queue for retry on next Supervisor run
                    continue
                }

                // Successfully recovered - dequeue from pending
                FlowYieldVaultsSchedulerRegistry.dequeuePending(yieldVaultID: yieldVaultID)
                emit YieldVaultRecovered(yieldVaultID: yieldVaultID)
            }

            // STEP 3: Self-reschedule for perpetual operation if configured
            if let interval = recurringInterval {
                self.scheduleNextRecurringExecution(
                    recurringInterval: interval,
                    priority: priority,
                    executionEffort: executionEffort,
                    scanForStuck: scanForStuck
                )
            }
        }

        /// Self-reschedules the Supervisor for perpetual operation.
        ///
        /// This function handles the scheduling of the next Supervisor execution,
        /// including fee estimation, withdrawal, and transaction scheduling.
        ///
        /// @param recurringInterval: The interval in seconds until the next execution
        /// @param priority: The priority level for the scheduled transaction
        /// @param executionEffort: The execution effort estimate for the transaction
        /// @param scanForStuck: Whether to scan for stuck yield vaults in the next execution
        access(Schedule) fun scheduleNextRecurringExecution(
            recurringInterval: UFix64,
            priority: FlowTransactionScheduler.Priority,
            executionEffort: UInt64,
            scanForStuck: Bool
        ) {
            let ref = &self._scheduledTransaction as &FlowTransactionScheduler.ScheduledTransaction?

            if ref?.status() == FlowTransactionScheduler.Status.Scheduled {
                // already scheduled - do nothing
                return
            }
            let txn <- self._scheduledTransaction <- nil
            destroy txn

            let nextTimestamp = getCurrentBlock().timestamp + recurringInterval
            let supervisorCap = FlowYieldVaultsSchedulerRegistry.getSupervisorCap()

            if supervisorCap == nil || !supervisorCap!.check() {
                return
            }

            let est = FlowYieldVaultsSchedulerV1.estimateSchedulingCost(
                timestamp: nextTimestamp,
                priority: priority,
                executionEffort: executionEffort
            )
            let baseFee = est.flowFee ?? FlowYieldVaultsSchedulerV1.MIN_FEE_FALLBACK
            let required = baseFee * FlowYieldVaultsSchedulerV1.FEE_MARGIN_MULTIPLIER

            if let vaultRef = self.feesCap.borrow() {
                if vaultRef.balance >= required {
                    let fees <- vaultRef.withdraw(amount: required) as! @FlowToken.Vault

                    let nextData: {String: AnyStruct} = {
                        "priority": priority.rawValue,
                        "executionEffort": executionEffort,
                        "recurringInterval": recurringInterval,
                        "scanForStuck": scanForStuck
                    }

                    let selfTxn <- FlowTransactionScheduler.schedule(
                        handlerCap: supervisorCap!,
                        data: nextData,
                        timestamp: nextTimestamp,
                        priority: priority,
                        executionEffort: executionEffort,
                        fees: <-fees
                    )

                    emit SupervisorRescheduled(
                        scheduledTransactionID: selfTxn.id,
                        timestamp: nextTimestamp
                    )

                    self._scheduledTransaction <-! selfTxn
                }
            }
        }

        /// Cancels the scheduled transaction if it is scheduled.
        ///
        /// @param refundReceiver: The receiver of the refunded vault, or nil to deposit to the internal feesCap
        ///
        /// @return @FlowToken.Vault?: The refunded vault, or nil if a scheduled transaction is not found
        access(Schedule) fun cancelScheduledTransaction(refundReceiver: &{FungibleToken.Vault}?): @FlowToken.Vault? {
            // nothing to cancel - nil or not scheduled
            if self._scheduledTransaction == nil
                || self._scheduledTransaction?.status() != FlowTransactionScheduler.Status.Scheduled {
                return nil
            }
            // cancel the scheduled transaction & deposit refund to receiver if provided
            let txnID = self.getScheduledTransactionID()!
            let txn <- self._scheduledTransaction <- nil
            let refund <- FlowTransactionScheduler.cancel(scheduledTx: <-txn!)
            if let receiver = refundReceiver {
                receiver.deposit(from: <-refund)
            } else {
                let feeReceiver = self.feesCap.borrow()
                    ?? panic("Could not borrow fees receiver to deposit refund of \(refund.balance) FLOW when cancelling scheduled transaction id \(txnID)")
                feeReceiver.deposit(from: <-refund)
            }
            return nil
        }
    }

    /* --- PRIVATE FUNCTIONS --- */

    /// Creates a Supervisor handler.
    access(self) fun createSupervisor(): @Supervisor {
        let feesCap = self.account.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
        return <- create Supervisor(feesCap: feesCap)
    }

    /* --- PUBLIC FUNCTIONS --- */

    /// Estimates the cost of scheduling a transaction at a given timestamp
    access(all) fun estimateSchedulingCost(
        timestamp: UFix64,
        priority: FlowTransactionScheduler.Priority,
        executionEffort: UInt64
    ): FlowTransactionScheduler.EstimatedScheduledTransaction {
        let maximumSizeData: {String: AnyStruct} = {
            "priority": priority.rawValue,
            "executionEffort": executionEffort,
            "recurringInterval": UFix64.max,
            "scanForStuck": true
        }
        return FlowTransactionScheduler.estimate(
            data: maximumSizeData,
            timestamp: timestamp,
            priority: priority,
            executionEffort: executionEffort
        )
    }

    /// Ensures the Supervisor is configured and registered.
    /// Creates Supervisor if not exists, issues capability, and registers with Registry.
    /// Note: This is access(all) because the Supervisor is owned by the contract account
    /// and uses contract account funds. The function is idempotent and safe to call multiple times.
    access(all) fun ensureSupervisorConfigured() {
        // Create and save Supervisor if not exists
        if self.account.storage.type(at: self.SupervisorStoragePath) == nil {
            let supervisor <- self.createSupervisor()
            self.account.storage.save(<-supervisor, to: self.SupervisorStoragePath)
        }

        // Check if Supervisor capability is already registered
        if FlowYieldVaultsSchedulerRegistry.getSupervisorCap() != nil {
            return
        }

        // Issue capability and register
        let cap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
            self.SupervisorStoragePath
        )
        FlowYieldVaultsSchedulerRegistry.setSupervisorCap(cap: cap)
    }

    /* --- ACCOUNT FUNCTIONS --- */

    /// Borrows the Supervisor reference (account-restricted for internal use)
    access(account) fun borrowSupervisor(): &Supervisor? {
        return self.account.storage.borrow<&Supervisor>(from: self.SupervisorStoragePath)
    }

    /// Manually enqueues a registered yield vault to the pending queue for recovery.
    /// This allows manual triggering of recovery for a specific yield vault.
    ///
    /// @param yieldVaultID: The ID of the registered yield vault to enqueue
    ///
    access(account) fun enqueuePendingYieldVault(yieldVaultID: UInt64) {
        assert(
            FlowYieldVaultsSchedulerRegistry.isRegistered(yieldVaultID: yieldVaultID),
            message: "enqueuePendingYieldVault: YieldVault #".concat(yieldVaultID.toString()).concat(" is not registered")
        )
        FlowYieldVaultsSchedulerRegistry.enqueuePending(yieldVaultID: yieldVaultID)
    }

    init() {
        // Initialize constants
        self.DEFAULT_RECURRING_INTERVAL = 60.0 * 10.0  // 10 minutes
        self.DEFAULT_PRIORITY = 1  // Medium
        self.DEFAULT_EXECUTION_EFFORT = 800
        self.MIN_FEE_FALLBACK = 0.00005
        self.FEE_MARGIN_MULTIPLIER = 1.0

        // Initialize paths
        self.SupervisorStoragePath = /storage/FlowYieldVaultsSupervisor
        
        // Configure Supervisor at deploy time
        self.ensureSupervisorConfigured()
    }
}

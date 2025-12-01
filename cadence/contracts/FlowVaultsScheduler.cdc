// standards
import "FungibleToken"
import "FlowToken"
// Flow system contracts
import "FlowTransactionScheduler"
// DeFiActions
import "DeFiActions"
// Registry storage (separate contract)
import "FlowVaultsSchedulerRegistry"
// AutoBalancer management (for detecting stuck yield vaults)
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
/// - Supervisor detects stuck yield vaults (failed to self-schedule) and recovers them
/// - Uses Schedule capability to directly call AutoBalancer.scheduleNextRebalance()
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

    /* --- RESOURCES --- */

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

        init(
            feesCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
        ) {
            self.feesCap = feesCap
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
            let priorityRaw = cfg["priority"] as? UInt8 ?? FlowVaultsScheduler.DEFAULT_PRIORITY
            let executionEffort = cfg["executionEffort"] as? UInt64 ?? FlowVaultsScheduler.DEFAULT_EXECUTION_EFFORT
            let recurringInterval = cfg["recurringInterval"] as? UFix64
            let scanForStuck = cfg["scanForStuck"] as? Bool ?? true

            let priority = FlowTransactionScheduler.Priority(rawValue: priorityRaw)
                ?? FlowTransactionScheduler.Priority.Medium

            // STEP 1: State-based detection - scan for stuck yield vaults
            if scanForStuck {
                let registeredYieldVaults = FlowVaultsSchedulerRegistry.getRegisteredYieldVaultIDs()
                var scanned = 0
                for yieldVaultID in registeredYieldVaults {
                    if scanned >= FlowVaultsSchedulerRegistry.MAX_BATCH_SIZE {
                        break
                    }
                    scanned = scanned + 1
                    
                    // Skip if already in pending queue
                    if FlowVaultsSchedulerRegistry.getPendingYieldVaultIDs().contains(yieldVaultID) {
                        continue
                    }

                    // Check if yield vault is stuck (has recurring config, no active schedule, overdue)
                    if FlowVaultsAutoBalancers.isStuckYieldVault(id: yieldVaultID) {
                        FlowVaultsSchedulerRegistry.enqueuePending(yieldVaultID: yieldVaultID)
                        emit StuckYieldVaultDetected(yieldVaultID: yieldVaultID)
                    }
                }
            }

            // STEP 2: Process pending yield vaults - recover them via Schedule capability
            let pendingYieldVaults = FlowVaultsSchedulerRegistry.getPendingYieldVaultIDsPaginated(page: 0, size: nil)
            
            for yieldVaultID in pendingYieldVaults {
                // Get Schedule capability for this yield vault
                let scheduleCap = FlowVaultsSchedulerRegistry.getScheduleCap(yieldVaultID: yieldVaultID)
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
                FlowVaultsSchedulerRegistry.dequeuePending(yieldVaultID: yieldVaultID)
                emit YieldVaultRecovered(yieldVaultID: yieldVaultID)
            }

            // STEP 3: Self-reschedule for perpetual operation if configured
            // Only reschedule if there are still registered yield vaults to monitor
            if let interval = recurringInterval {
                if FlowVaultsSchedulerRegistry.getRegisteredYieldVaultIDs().length > 0 {
                    let nextTimestamp = getCurrentBlock().timestamp + interval
                    let supervisorCap = FlowVaultsSchedulerRegistry.getSupervisorCap()
                    
                    if supervisorCap != nil && supervisorCap!.check() {
                        let est = FlowVaultsScheduler.estimateSchedulingCost(
                            timestamp: nextTimestamp,
                            priority: priority,
                            executionEffort: executionEffort
                        )
                        let baseFee = est.flowFee ?? FlowVaultsScheduler.MIN_FEE_FALLBACK
                        let required = baseFee * FlowVaultsScheduler.FEE_MARGIN_MULTIPLIER
                        
                        if let vaultRef = self.feesCap.borrow() {
                            if vaultRef.balance >= required {
                                let fees <- vaultRef.withdraw(amount: required) as! @FlowToken.Vault

                                let nextData: {String: AnyStruct} = {
                                    "priority": priorityRaw,
                                    "executionEffort": executionEffort,
                                    "recurringInterval": interval,
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

                                destroy selfTxn
                            }
                        }
                    }
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

    /// Estimates the cost of scheduling a transaction at a given timestamp
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

    /* --- ACCOUNT FUNCTIONS --- */

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
        if FlowVaultsSchedulerRegistry.getSupervisorCap() != nil {
            return
        }

        // Issue capability and register
        let cap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
            self.SupervisorStoragePath
        )
        FlowVaultsSchedulerRegistry.setSupervisorCap(cap: cap)
    }

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
            FlowVaultsSchedulerRegistry.isRegistered(yieldVaultID: yieldVaultID),
            message: "enqueuePendingYieldVault: YieldVault #".concat(yieldVaultID.toString()).concat(" is not registered")
        )
        FlowVaultsSchedulerRegistry.enqueuePending(yieldVaultID: yieldVaultID)
    }

    init() {
        // Initialize constants
        self.DEFAULT_RECURRING_INTERVAL = 60.0  // 60 seconds
        self.DEFAULT_PRIORITY = 1  // Medium
        self.DEFAULT_EXECUTION_EFFORT = 800
        self.MIN_FEE_FALLBACK = 0.00005
        self.FEE_MARGIN_MULTIPLIER = 1.2
        self.DEFAULT_LOOKAHEAD_SECS = 10.0

        // Initialize paths
        self.SupervisorStoragePath = /storage/FlowVaultsSupervisor
        
        // Configure Supervisor at deploy time
        self.ensureSupervisorConfigured()
    }
}

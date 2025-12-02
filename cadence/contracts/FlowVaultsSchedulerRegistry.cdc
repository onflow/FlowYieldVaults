import "FlowTransactionScheduler"
import "DeFiActions"


/// FlowVaultsSchedulerRegistry
///
/// Stores registry of YieldVault IDs and their handler capabilities for scheduling.
/// This contract maintains:
/// - A registry of all yield vault IDs that participate in scheduled rebalancing
/// - Handler capabilities (AutoBalancer capabilities) for each yield vault
/// - A pending queue for yield vaults that need initial seeding or re-seeding
/// - The global Supervisor capability for recovery operations
///
access(all) contract FlowVaultsSchedulerRegistry {

    /* --- EVENTS --- */

    /// Emitted when a yield vault is registered with its handler capability
    access(all) event YieldVaultRegistered(yieldVaultID: UInt64)

    /// Emitted when a yield vault is unregistered (cleanup on yield vault close)
    access(all) event YieldVaultUnregistered(
        yieldVaultID: UInt64,
        wasInPendingQueue: Bool
    )

    /// Emitted when a yield vault is added to the pending queue for seeding/re-seeding
    access(all) event YieldVaultEnqueuedPending(
        yieldVaultID: UInt64,
        pendingQueueSize: Int
    )

    /// Emitted when a yield vault is removed from the pending queue (after successful scheduling)
    access(all) event YieldVaultDequeuedPending(
        yieldVaultID: UInt64,
        pendingQueueSize: Int
    )

    /* --- CONSTANTS --- */

    /// Maximum number of yield vaults to process in a single Supervisor batch
    access(all) let MAX_BATCH_SIZE: Int

    /* --- STATE --- */

    /// Registry of all yield vault IDs that participate in scheduling
    access(self) var yieldVaultRegistry: {UInt64: Bool}

    /// Handler capabilities (AutoBalancer) for each yield vault - keyed by yield vault ID
    /// Used for scheduling via FlowTransactionScheduler
    access(self) var handlerCaps: {UInt64: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>}

    /// Schedule capabilities for each yield vault - keyed by yield vault ID
    /// Used by Supervisor to directly call scheduleNextRebalance() for recovery
    access(self) var scheduleCaps: {UInt64: Capability<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>}

    /// Queue of yield vault IDs that need initial seeding or re-seeding by the Supervisor
    /// Stored as a dictionary for O(1) add/remove; iteration gives the pending set
    access(self) var pendingQueue: {UInt64: Bool}

    /// Global Supervisor capability (used for self-rescheduling)
    access(self) var supervisorCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>?

    /* --- ACCOUNT-LEVEL FUNCTIONS --- */

    /// Register a YieldVault and store its handler and schedule capabilities (idempotent)
    access(account) fun register(
        yieldVaultID: UInt64,
        handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
        scheduleCap: Capability<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>
    ) {
        pre {
            handlerCap.check(): "Invalid handler capability provided for yieldVaultID \(yieldVaultID)"
            scheduleCap.check(): "Invalid schedule capability provided for yieldVaultID \(yieldVaultID)"
        }
        self.yieldVaultRegistry[yieldVaultID] = true
        self.handlerCaps[yieldVaultID] = handlerCap
        self.scheduleCaps[yieldVaultID] = scheduleCap
        emit YieldVaultRegistered(yieldVaultID: yieldVaultID)
    }

    /// Adds a yield vault to the pending queue for seeding by the Supervisor
    access(account) fun enqueuePending(yieldVaultID: UInt64) {
        if self.yieldVaultRegistry[yieldVaultID] == true {
            self.pendingQueue[yieldVaultID] = true
            emit YieldVaultEnqueuedPending(yieldVaultID: yieldVaultID, pendingQueueSize: self.pendingQueue.length)
        }
    }

    /// Removes a yield vault from the pending queue (called after successful scheduling)
    access(account) fun dequeuePending(yieldVaultID: UInt64) {
        let removed = self.pendingQueue.remove(key: yieldVaultID)
        if removed != nil {
            emit YieldVaultDequeuedPending(yieldVaultID: yieldVaultID, pendingQueueSize: self.pendingQueue.length)
        }
    }

    /// Unregister a YieldVault (idempotent) - removes from registry, capabilities, and pending queue
    access(account) fun unregister(yieldVaultID: UInt64) {
        self.yieldVaultRegistry.remove(key: yieldVaultID)
        self.handlerCaps.remove(key: yieldVaultID)
        self.scheduleCaps.remove(key: yieldVaultID)
        let pending = self.pendingQueue.remove(key: yieldVaultID)
        emit YieldVaultUnregistered(yieldVaultID: yieldVaultID, wasInPendingQueue: pending != nil)
    }

    /// Set global Supervisor capability (used for self-rescheduling)
    access(account) fun setSupervisorCap(cap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>) {
        self.supervisorCap = cap
    }

    /* --- VIEW FUNCTIONS --- */

    /// Get all registered YieldVault IDs
    /// WARNING: This can be expensive for large registries - prefer getPendingYieldVaultIDs for Supervisor operations
    access(all) view fun getRegisteredYieldVaultIDs(): [UInt64] {
        return self.yieldVaultRegistry.keys
    }

    /// Get handler capability for a YieldVault (AutoBalancer capability) - account restricted for internal use
    access(account) view fun getHandlerCap(yieldVaultID: UInt64): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.handlerCaps[yieldVaultID]
    }

    /// Get handler capability for a YieldVault - public version for transactions
    /// NOTE: The capability is protected by FlowTransactionScheduler.Execute entitlement,
    /// so having it only allows scheduling (which requires paying fees), not direct execution.
    access(all) view fun getHandlerCapability(yieldVaultID: UInt64): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.handlerCaps[yieldVaultID]
    }

    /// Get schedule capability for a YieldVault - account restricted for Supervisor use
    /// This allows calling scheduleNextRebalance() directly on the AutoBalancer
    access(account) view fun getScheduleCap(yieldVaultID: UInt64): Capability<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>? {
        return self.scheduleCaps[yieldVaultID]
    }

    /// Returns true if the yield vault is registered
    access(all) view fun isRegistered(yieldVaultID: UInt64): Bool {
        return self.yieldVaultRegistry[yieldVaultID] ?? false
    }

    /// Get all yield vault IDs in the pending queue
    access(all) view fun getPendingYieldVaultIDs(): [UInt64] {
        return self.pendingQueue.keys
    }

    /// Get paginated pending yield vault IDs
    /// @param page: The page number (0-indexed)
    /// @param size: The page size (defaults to MAX_BATCH_SIZE if nil)
    access(all) view fun getPendingYieldVaultIDsPaginated(page: Int, size: Int?): [UInt64] {
        let pageSize = size ?? self.MAX_BATCH_SIZE
        let allPending = self.pendingQueue.keys
        let startIndex = page * pageSize
        
        if startIndex >= allPending.length {
            return []
        }
        
        let endIndex = startIndex + pageSize > allPending.length 
            ? allPending.length 
            : startIndex + pageSize
            
        return allPending.slice(from: startIndex, upTo: endIndex)
    }

    /// Returns the total number of yield vaults in the pending queue
    access(all) view fun getPendingCount(): Int {
        return self.pendingQueue.length
    }

    /// Get global Supervisor capability, if set
    /// NOTE: Access restricted - only used internally by the scheduler
    access(account) view fun getSupervisorCap(): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.supervisorCap
    }

    init() {
        self.MAX_BATCH_SIZE = 5  // Process up to 5 yield vaults per Supervisor run
        self.yieldVaultRegistry = {}
        self.handlerCaps = {}
        self.scheduleCaps = {}
        self.pendingQueue = {}
        self.supervisorCap = nil
    }
}



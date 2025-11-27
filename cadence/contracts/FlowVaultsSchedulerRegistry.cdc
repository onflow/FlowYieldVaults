import "FlowTransactionScheduler"


/// FlowVaultsSchedulerRegistry
///
/// Stores registry of Tide IDs and their handler capabilities for scheduling.
/// This contract maintains:
/// - A registry of all tide IDs that participate in scheduled rebalancing
/// - Handler capabilities (AutoBalancer capabilities) for each tide
/// - A pending queue for tides that need initial seeding or re-seeding
/// - The global Supervisor capability for recovery operations
///
access(all) contract FlowVaultsSchedulerRegistry {

    /* --- EVENTS --- */

    /// Emitted when a tide is registered with its handler capability
    access(all) event TideRegistered(tideID: UInt64)

    /// Emitted when a tide is unregistered (cleanup on tide close)
    access(all) event TideUnregistered(
        tideID: UInt64,
        wasInPendingQueue: Bool
    )

    /// Emitted when a tide is added to the pending queue for seeding/re-seeding
    access(all) event TideEnqueuedPending(
        tideID: UInt64,
        pendingQueueSize: Int
    )

    /// Emitted when a tide is removed from the pending queue (after successful scheduling)
    access(all) event TideDequeuedPending(
        tideID: UInt64,
        pendingQueueSize: Int
    )

    /* --- CONSTANTS --- */

    /// Maximum number of tides to process in a single Supervisor batch
    access(all) let MAX_BATCH_SIZE: Int

    /* --- STATE --- */

    /// Registry of all tide IDs that participate in scheduling
    access(self) var tideRegistry: {UInt64: Bool}

    /// Handler capabilities (AutoBalancer) for each tide - keyed by tide ID
    access(self) var handlerCaps: {UInt64: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>}

    /// Queue of tide IDs that need initial seeding or re-seeding by the Supervisor
    /// Stored as a dictionary for O(1) add/remove; iteration gives the pending set
    access(self) var pendingQueue: {UInt64: Bool}

    /// Global Supervisor capability (used for self-rescheduling)
    access(self) var supervisorCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>?

    /* --- ACCOUNT-LEVEL FUNCTIONS --- */

    /// Register a Tide and store its handler capability (idempotent)
    access(account) fun register(
        tideID: UInt64,
        handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
    ) {
        pre {
            handlerCap.check(): "Invalid handler capability provided for tideID \(tideID)"
        }
        self.tideRegistry[tideID] = true
        self.handlerCaps[tideID] = handlerCap
        emit TideRegistered(tideID: tideID)
    }

    /// Adds a tide to the pending queue for seeding by the Supervisor
    access(account) fun enqueuePending(tideID: UInt64) {
        if self.tideRegistry[tideID] == true {
            self.pendingQueue[tideID] = true
            emit TideEnqueuedPending(tideID: tideID, pendingQueueSize: self.pendingQueue.length)
        }
    }

    /// Removes a tide from the pending queue (called after successful scheduling)
    access(account) fun dequeuePending(tideID: UInt64) {
        let removed = self.pendingQueue.remove(key: tideID)
        if removed != nil {
            emit TideDequeuedPending(tideID: tideID, pendingQueueSize: self.pendingQueue.length)
        }
    }

    /// Unregister a Tide (idempotent) - removes from registry, capabilities, and pending queue
    access(account) fun unregister(tideID: UInt64) {
        self.tideRegistry.remove(key: tideID)
        self.handlerCaps.remove(key: tideID)
        let pending = self.pendingQueue.remove(key: tideID)
        emit TideUnregistered(tideID: tideID, wasInPendingQueue: pending != nil)
    }

    /// Set global Supervisor capability (used for self-rescheduling)
    access(account) fun setSupervisorCap(cap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>) {
        self.supervisorCap = cap
    }

    /* --- VIEW FUNCTIONS --- */

    /// Get all registered Tide IDs
    /// WARNING: This can be expensive for large registries - prefer getPendingTideIDs for Supervisor operations
    access(all) view fun getRegisteredTideIDs(): [UInt64] {
        return self.tideRegistry.keys
    }

    /// Get handler capability for a Tide (AutoBalancer capability) - account restricted for internal use
    access(account) view fun getHandlerCap(tideID: UInt64): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.handlerCaps[tideID]
    }

    /// Get handler capability for a Tide - public version for transactions
    /// NOTE: The capability is protected by FlowTransactionScheduler.Execute entitlement,
    /// so having it only allows scheduling (which requires paying fees), not direct execution.
    access(all) view fun getHandlerCapability(tideID: UInt64): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.handlerCaps[tideID]
    }

    /// Returns true if the tide is registered
    access(all) view fun isRegistered(tideID: UInt64): Bool {
        return self.tideRegistry[tideID] ?? false
    }

    /// Get all tide IDs in the pending queue
    access(all) view fun getPendingTideIDs(): [UInt64] {
        return self.pendingQueue.keys
    }

    /// Get paginated pending tide IDs
    /// @param page: The page number (0-indexed)
    /// @param size: The page size (defaults to MAX_BATCH_SIZE if nil)
    access(all) view fun getPendingTideIDsPaginated(page: Int, size: Int?): [UInt64] {
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

    /// Returns the total number of tides in the pending queue
    access(all) view fun getPendingCount(): Int {
        return self.pendingQueue.length
    }

    /// Get global Supervisor capability, if set
    /// NOTE: Access restricted - only used internally by the scheduler
    access(account) view fun getSupervisorCap(): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.supervisorCap
    }

    init() {
        self.MAX_BATCH_SIZE = 5  // Process up to 5 tides per Supervisor run
        self.tideRegistry = {}
        self.handlerCaps = {}
        self.pendingQueue = {}
        self.supervisorCap = nil
    }
}



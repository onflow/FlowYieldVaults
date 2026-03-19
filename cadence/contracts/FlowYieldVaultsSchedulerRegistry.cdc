import "FlowTransactionScheduler"
import "DeFiActions"
import "UInt64LinkedList"


/// FlowYieldVaultsSchedulerRegistry
///
/// Stores the global registry of live YieldVault IDs and their scheduling capabilities.
/// This contract maintains:
/// - A registry of all live yield vault IDs known to the scheduler infrastructure
/// - Handler capabilities (AutoBalancer capabilities) for each yield vault
/// - A pending queue for yield vaults that need initial seeding or re-seeding
/// - A recurring-only stuck-scan ordering used by the Supervisor
/// - The global Supervisor capability for recovery operations
///
access(all) contract FlowYieldVaultsSchedulerRegistry {

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

    /* --- STORAGE PATHS --- */

    access(all) let executionListStoragePath: StoragePath

    /* --- STATE --- */

    /// Registry of all live yield vault IDs known to the scheduler infrastructure.
    /// This is broader than the recurring-only stuck-scan ordering.
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

    /* --- PRIVATE LIST ACCESSOR --- */

    /// Borrow the execution-order linked list from account storage.
    access(self) fun _list(): &UInt64LinkedList.List {
        return self.account.storage
            .borrow<&UInt64LinkedList.List>(from: self.executionListStoragePath)
            ?? panic("UInt64LinkedList.List resource missing from storage")
    }

    /* --- ACCOUNT-LEVEL FUNCTIONS --- */

    /// Register a YieldVault and store its handler and schedule capabilities (idempotent)
    /// `participatesInStuckScan` should be true only for vaults that currently have recurring config.
    access(account) fun register(
        yieldVaultID: UInt64,
        handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
        scheduleCap: Capability<auth(DeFiActions.Schedule) &DeFiActions.AutoBalancer>,
        participatesInStuckScan: Bool
    ) {
        pre {
            handlerCap.check(): "Invalid handler capability provided for yieldVaultID \(yieldVaultID)"
            scheduleCap.check(): "Invalid schedule capability provided for yieldVaultID \(yieldVaultID)"
        }
        self.yieldVaultRegistry[yieldVaultID] = true
        self.handlerCaps[yieldVaultID] = handlerCap
        self.scheduleCaps[yieldVaultID] = scheduleCap

        // The registry tracks all live yield vaults, but only recurring vaults
        // participate in the Supervisor's stuck-scan ordering.
        // If already in the list (idempotent re-register), remove first to avoid duplicates.
        let list = self._list()
        if list.contains(id: yieldVaultID) {
            let _ = list.remove(id: yieldVaultID)
        }
        if participatesInStuckScan {
            list.insertAtHead(id: yieldVaultID)
        }
        emit YieldVaultRegistered(yieldVaultID: yieldVaultID)
    }

    /// Called on every execution. Moves scan-participating yieldVaultID to the head
    /// (most recently executed) so the Supervisor scans recurring participants from the tail
    /// (least recently executed) for stuck detection — O(1).
    access(account) fun reportExecution(yieldVaultID: UInt64) {
        let list = self._list()
        if !(self.yieldVaultRegistry[yieldVaultID] ?? false) || !list.contains(id: yieldVaultID) {
            return
        }
        let _ = list.remove(id: yieldVaultID)
        list.insertAtHead(id: yieldVaultID)
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

    /// Unregister a YieldVault (idempotent) - removes from registry, capabilities, pending queue, and linked list
    access(account) fun unregister(yieldVaultID: UInt64) {
        let _r = self.yieldVaultRegistry.remove(key: yieldVaultID)
        let _h = self.handlerCaps.remove(key: yieldVaultID)
        let _s = self.scheduleCaps.remove(key: yieldVaultID)
        let pending = self.pendingQueue.remove(key: yieldVaultID)
        let _ = self._list().remove(id: yieldVaultID)
        emit YieldVaultUnregistered(yieldVaultID: yieldVaultID, wasInPendingQueue: pending != nil)
    }

    /// Set global Supervisor capability (used for self-rescheduling)
    access(account)
    fun setSupervisorCap(cap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>) {
        let storedCapPath = /storage/FlowYieldVaultsSupervisorCapability
        let old = self.account.storage
            .load<Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>>(
                from: storedCapPath
            )
        self.account.storage.save(cap, to: storedCapPath)
    }

    /* --- VIEW FUNCTIONS --- */

    /// Get all registered YieldVault IDs
    /// WARNING: This can be expensive for large registries - prefer getPendingYieldVaultIDs for Supervisor operations
    access(all) view fun getRegisteredYieldVaultIDs(): [UInt64] {
        return self.yieldVaultRegistry.keys
    }

    /// Get the number of currently registered yield vaults
    access(all) view fun getRegisteredCount(): Int {
        return self.yieldVaultRegistry.length
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
    /// @param size: The page size (defaults to MAX_BATCH_SIZE if 0)
    access(all) view fun getPendingYieldVaultIDsPaginated(page: Int, size: UInt): [UInt64] {
        let pageSize = size == 0 ? self.MAX_BATCH_SIZE : Int(size)
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

    /// Returns up to `limit` recurring scan participants starting from the tail
    /// (least recently executed among recurring participants).
    /// Stale entries whose recurring config has been removed are pruned lazily as the walk proceeds.
    /// Supervisor should only scan these for stuck detection instead of all registered vaults.
    /// @param limit: Maximum number of IDs to return (caller typically passes MAX_BATCH_SIZE)
    access(all) fun getStuckScanCandidates(limit: UInt): [UInt64] {
        let list = self._list()
        var result: [UInt64] = []
        var current = list.tail
        while UInt(result.length) < limit {
            if let id = current {
                let previous = list.nodes[id]?.prev
                let scheduleCap = self.scheduleCaps[id]
                let isRecurringParticipant =
                    scheduleCap != nil
                    && scheduleCap!.check()
                    && scheduleCap!.borrow()?.getRecurringConfig() != nil

                if isRecurringParticipant {
                    result.append(id)
                } else {
                    self.dequeuePending(yieldVaultID: id)
                    let _ = list.remove(id: id)
                }
                current = previous
            } else {
                break
            }
        }
        return result
    }

    /// Get global Supervisor capability, if set
    /// NOTE: Access restricted - only used internally by the scheduler
    access(account)
    view fun getSupervisorCap(): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.account.storage
            .copy<Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>>(
                from: /storage/FlowYieldVaultsSupervisorCapability
            )
    }

    init() {
        self.MAX_BATCH_SIZE = 5  // Process up to 5 yield vaults per Supervisor run
        self.executionListStoragePath = /storage/FlowYieldVaultsExecutionList
        self.yieldVaultRegistry = {}
        self.handlerCaps = {}
        self.scheduleCaps = {}
        self.pendingQueue = {}
        self.account.storage.save(<- UInt64LinkedList.createList(), to: self.executionListStoragePath)
    }
}

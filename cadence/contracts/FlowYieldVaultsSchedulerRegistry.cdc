import "FlowTransactionScheduler"
import "DeFiActions"


/// FlowYieldVaultsSchedulerRegistry
///
/// Stores registry of YieldVault IDs and their handler capabilities for scheduling.
/// This contract maintains:
/// - A registry of all yield vault IDs that participate in scheduled rebalancing
/// - Handler capabilities (AutoBalancer capabilities) for each yield vault
/// - A pending queue for yield vaults that need initial seeding or re-seeding
/// - The global Supervisor capability for recovery operations
///
access(all) contract FlowYieldVaultsSchedulerRegistry {

    /* --- TYPES --- */

    /// Node in the simulated doubly-linked list used for O(1) stuck-scan ordering.
    /// `prev` points toward the head (most recently executed); `next` points toward the tail (oldest/least recently executed).
    access(all) struct ListNode {
        access(all) var prev: UInt64?
        access(all) var next: UInt64?
        init(prev: UInt64?, next: UInt64?) {
            self.prev = prev
            self.next = next
        }

        access(all) fun setPrev(prev: UInt64?) {
            self.prev = prev
        }

        access(all) fun setNext(next: UInt64?) {
            self.next = next
        }
    }

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

    /// Simulated doubly-linked list for O(1) stuck-scan ordering.
    /// listHead = most recently executed vault ID (or nil if empty).
    /// listTail = least recently executed vault ID — getStuckScanCandidates walks from here.
    /// On reportExecution a vault is snipped from its current position and moved to head in O(1).
    access(self) var listNodes: {UInt64: ListNode}
    access(self) var listHead: UInt64?
    access(self) var listTail: UInt64?

    /* --- PRIVATE LIST HELPERS --- */

    /// Insert `id` at the head of the list (most-recently-executed end).
    /// Caller must ensure `id` is not already in the list.
    access(self) fun _listInsertAtHead(id: UInt64) {
        let node = ListNode(prev: nil, next: self.listHead)
        if let oldHeadID = self.listHead {
            var oldHead = self.listNodes[oldHeadID]!
            oldHead.setPrev(prev: id)
            self.listNodes[oldHeadID] = oldHead
        } else {
            // List was empty — id is also the tail
            self.listTail = id
        }
        self.listNodes[id] = node
        self.listHead = id
    }

    /// Remove `id` from wherever it sits in the list in O(1).
    access(self) fun _listRemove(id: UInt64) {
        let node = self.listNodes.remove(key: id) ?? panic("Node not found")

        if let prevID = node.prev {
            var prevNode = self.listNodes[prevID]!
            prevNode.setNext(next: node.next)
            self.listNodes[prevID] = prevNode
        } else {
            // id was the head
            self.listHead = node.next
        }

        if let nextID = node.next {
            var nextNode = self.listNodes[nextID]!
            nextNode.setPrev(prev: node.prev)
            self.listNodes[nextID] = nextNode
        } else {
            // id was the tail
            self.listTail = node.prev
        }
    }

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
        // New vaults go to the head; they haven't executed yet but are freshly registered.
        // If already in the list (idempotent re-register), remove first to avoid duplicates.
        if self.listNodes[yieldVaultID] != nil {
            self._listRemove(id: yieldVaultID)
        }
        self._listInsertAtHead(id: yieldVaultID)
        emit YieldVaultRegistered(yieldVaultID: yieldVaultID)
    }

    /// Called on every execution. Moves yieldVaultID to the head (most recently executed)
    /// so the Supervisor scans from the tail (least recently executed) for stuck detection — O(1).
    access(account) fun reportExecution(yieldVaultID: UInt64) {
        if !(self.yieldVaultRegistry[yieldVaultID] ?? false) {
            return
        }
        self._listRemove(id: yieldVaultID)
        self._listInsertAtHead(id: yieldVaultID)
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
        self._listRemove(id: yieldVaultID)
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
        self.account.storage.save(cap,to: storedCapPath)
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

        let endIndex = startIndex + Int(pageSize) > allPending.length
            ? allPending.length
            : startIndex + Int(pageSize)

        return allPending.slice(from: startIndex, upTo: endIndex)
    }

    /// Returns the total number of yield vaults in the pending queue
    access(all) view fun getPendingCount(): Int {
        return self.pendingQueue.length
    }

    /// Returns up to `limit` vault IDs starting from the tail (least recently executed).
    /// Supervisor should only scan these for stuck detection instead of all registered vaults.
    /// @param limit: Maximum number of IDs to return (caller typically passes MAX_BATCH_SIZE)
    access(all) fun getStuckScanCandidates(limit: UInt): [UInt64] {
        var result: [UInt64] = []
        var current = self.listTail
        var count: UInt = 0
        while count < limit {
            if let id = current {
                result.append(id)
                current = self.listNodes[id]?.prev
                count = count + 1
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
        self.yieldVaultRegistry = {}
        self.handlerCaps = {}
        self.scheduleCaps = {}
        self.pendingQueue = {}
        self.listNodes = {}
        self.listHead = nil
        self.listTail = nil
    }
}

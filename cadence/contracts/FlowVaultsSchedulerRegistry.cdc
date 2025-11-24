import "FlowTransactionScheduler"


/// Stores registry of Tide IDs and their wrapper capabilities for scheduling.
access(all) contract FlowVaultsSchedulerRegistry {

    access(self) var tideRegistry: {UInt64: Bool}
    access(self) var wrapperCaps: {UInt64: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>}
    access(self) var supervisorCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>?

    /// Register a Tide and store its wrapper capability (idempotent)
    access(account) fun register(
        tideID: UInt64,
        wrapperCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
    ) {
        self.tideRegistry[tideID] = true
        self.wrapperCaps[tideID] = wrapperCap
    }

    /// Unregister a Tide (idempotent)
    access(account) fun unregister(tideID: UInt64) {
        let _removedReg = self.tideRegistry.remove(key: tideID)
        let _removedCap = self.wrapperCaps.remove(key: tideID)
    }

    /// Get all registered Tide IDs
    access(all) fun getRegisteredTideIDs(): [UInt64] {
        return self.tideRegistry.keys
    }

    /// Get wrapper capability for Tide
    access(all) fun getWrapperCap(tideID: UInt64): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.wrapperCaps[tideID]
    }

    /// Set global Supervisor capability (used for self-rescheduling)
    access(account) fun setSupervisorCap(cap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>) {
        self.supervisorCap = cap
    }

    /// Get global Supervisor capability, if set
    access(all) fun getSupervisorCap(): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? {
        return self.supervisorCap
    }

    init() {
        self.tideRegistry = {}
        self.wrapperCaps = {}
        self.supervisorCap = nil
    }
}



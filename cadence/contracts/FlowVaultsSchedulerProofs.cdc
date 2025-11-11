/// Stores scheduler execution proofs for FlowVaults Tides
/// Separate contract so FlowVaultsScheduler can be upgraded without storage layout changes.
access(all) contract FlowVaultsSchedulerProofs {

    /// tideID -> (scheduledTransactionID -> true)
    access(self) var executedByScheduler: {UInt64: {UInt64: Bool}}

    /// Records that a scheduled transaction for a Tide was executed
    access(all) fun markExecuted(tideID: UInt64, scheduledTransactionID: UInt64) {
        let current = self.executedByScheduler[tideID] ?? {} as {UInt64: Bool}
        var updated = current
        updated[scheduledTransactionID] = true
        self.executedByScheduler[tideID] = updated
    }

    /// Returns true if the given scheduled transaction was executed
    access(all) fun wasExecuted(tideID: UInt64, scheduledTransactionID: UInt64): Bool {
        let byTide = self.executedByScheduler[tideID] ?? {} as {UInt64: Bool}
        return byTide[scheduledTransactionID] ?? false
    }

    /// Returns the executed scheduled transaction IDs for the Tide
    access(all) fun getExecutedIDs(tideID: UInt64): [UInt64] {
        let byTide = self.executedByScheduler[tideID] ?? {} as {UInt64: Bool}
        return byTide.keys
    }

    init() {
        self.executedByScheduler = {}
    }
}



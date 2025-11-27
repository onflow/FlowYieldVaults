import "FlowVaultsSchedulerRegistry"

/// Returns the number of tides in the pending queue awaiting seeding
access(all) fun main(): Int {
    return FlowVaultsSchedulerRegistry.getPendingCount()
}


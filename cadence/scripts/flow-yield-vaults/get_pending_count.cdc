import "FlowYieldVaultsSchedulerRegistry"

/// Returns the number of yield vaults in the pending queue awaiting seeding
access(all) fun main(): Int {
    return FlowYieldVaultsSchedulerRegistry.getPendingCount()
}


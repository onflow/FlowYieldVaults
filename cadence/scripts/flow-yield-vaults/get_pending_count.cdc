import "FlowYieldVaultsSchedulerRegistryV1"

/// Returns the number of yield vaults in the pending queue awaiting seeding
access(all) fun main(): Int {
    return FlowYieldVaultsSchedulerRegistryV1.getPendingCount()
}


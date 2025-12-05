import "FlowYieldVaultsSchedulerRegistry"

access(all) fun main(): [UInt64] {
    return FlowYieldVaultsSchedulerRegistry.getRegisteredYieldVaultIDs()
}

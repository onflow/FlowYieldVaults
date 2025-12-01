import "FlowVaultsSchedulerRegistry"

access(all) fun main(): [UInt64] {
    return FlowVaultsSchedulerRegistry.getRegisteredYieldVaultIDs()
}

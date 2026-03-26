import "FlowYieldVaultsSchedulerRegistryV1"

access(all) fun main(): [UInt64] {
    return FlowYieldVaultsSchedulerRegistryV1.getRegisteredYieldVaultIDs()
}

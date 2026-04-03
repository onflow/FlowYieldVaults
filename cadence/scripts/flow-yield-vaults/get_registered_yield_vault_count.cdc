import "FlowYieldVaultsSchedulerRegistryV1"

/// Returns the count of registered yield vaults in the registry
///
/// @return Int: The number of registered yield vaults
///
access(all) fun main(): Int {
    return FlowYieldVaultsSchedulerRegistryV1.getRegisteredCount()
}


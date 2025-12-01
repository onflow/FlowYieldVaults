import "FlowVaultsSchedulerRegistry"

/// Returns the count of registered yield vaults in the registry
///
/// @return Int: The number of registered yield vaults
///
access(all) fun main(): Int {
    return FlowVaultsSchedulerRegistry.getRegisteredYieldVaultIDs().length
}


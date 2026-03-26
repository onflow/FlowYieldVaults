import "FlowYieldVaultsSchedulerRegistryV1"

/// Returns true if the scheduler registry has a handler capability (AutoBalancer)
/// stored for the given YieldVault ID.
/// Note: Uses isRegistered() since getHandlerCap is account-restricted for security.
access(all) fun main(yieldVaultID: UInt64): Bool {
    return FlowYieldVaultsSchedulerRegistryV1.isRegistered(yieldVaultID: yieldVaultID)
}




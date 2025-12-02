import "FlowVaultsSchedulerRegistry"

/// Returns true if the scheduler registry has a handler capability (AutoBalancer)
/// stored for the given YieldVault ID.
/// Note: Uses isRegistered() since getHandlerCap is account-restricted for security.
access(all) fun main(yieldVaultID: UInt64): Bool {
    return FlowVaultsSchedulerRegistry.isRegistered(yieldVaultID: yieldVaultID)
}




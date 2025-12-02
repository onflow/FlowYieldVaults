import "FlowYieldVaultsAutoBalancers"

/// Returns true if the yield vault/AutoBalancer has at least one active (Scheduled) transaction.
/// Used to verify that healthy yield vaults maintain their scheduling chain.
///
/// @param yieldVaultID: The YieldVault/AutoBalancer ID
/// @return Bool: true if there's at least one Scheduled transaction, false otherwise
///
access(all) fun main(yieldVaultID: UInt64): Bool {
    return FlowYieldVaultsAutoBalancers.hasActiveSchedule(id: yieldVaultID)
}


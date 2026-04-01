import "FlowYieldVaultsAutoBalancers"

/// Returns true if the yield vault/AutoBalancer has at least one active internally-managed
/// transaction. Active includes `Scheduled`, plus a recently `Executed` transaction still
/// within the optimistic-execution grace period.
///
/// @param yieldVaultID: The YieldVault/AutoBalancer ID
/// @return Bool: true if there's at least one active internally-managed transaction, false otherwise
///
access(all) fun main(yieldVaultID: UInt64): Bool {
    return FlowYieldVaultsAutoBalancers.hasActiveSchedule(id: yieldVaultID)
}

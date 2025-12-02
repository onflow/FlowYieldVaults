import "FlowYieldVaultsAutoBalancers"

/// Returns true if the yield vault is stuck (overdue with no active schedule).
/// A yield vault is considered stuck if:
/// - It has a recurring config
/// - No active schedule exists
/// - The expected next execution time has passed
///
/// This is used by Supervisor to detect yield vaults that failed to self-reschedule.
///
/// @param yieldVaultID: The YieldVault/AutoBalancer ID
/// @return Bool: true if yield vault is stuck, false otherwise
///
access(all) fun main(yieldVaultID: UInt64): Bool {
    return FlowYieldVaultsAutoBalancers.isStuckYieldVault(id: yieldVaultID)
}


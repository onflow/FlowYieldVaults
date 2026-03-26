import "FlowYieldVaultsAutoBalancers"

/// Returns the balance of the AutoBalancer related to the provided YieldVault ID or `nil` if none exists
///
access(all)
fun main(id: UInt64): UFix64? {
    return FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: id)?.vaultBalance()
}

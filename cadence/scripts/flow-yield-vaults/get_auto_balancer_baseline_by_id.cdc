import "FlowYieldVaultsAutoBalancers"

/// Returns the baseline (valueOfDeposits) of the AutoBalancer related to the provided YieldVault ID or `nil` if none exists
///
access(all)
fun main(id: UInt64): UFix64? {
    return FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: id)?.valueOfDeposits()
}

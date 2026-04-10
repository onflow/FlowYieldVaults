import "FlowYieldVaultsAutoBalancers"

/// Returns the value of deposits tracked by the AutoBalancer related to the provided YieldVault ID or `nil` if none exists
/// This is the historical cumulative value used to compute the rebalance ratio: currentValue / valueOfDeposits
///
access(all)
fun main(id: UInt64): UFix64? {
    return FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: id)?.valueOfDeposits() ?? nil
}

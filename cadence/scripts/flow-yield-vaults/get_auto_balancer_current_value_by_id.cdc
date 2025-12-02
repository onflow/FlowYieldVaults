import "FlowYieldVaultsAutoBalancers"

/// Returns the current value of the AutoBalancer's balance related to the provided YieldVault ID or `nil` if none exists
///
access(all)
fun main(id: UInt64): UFix64? {
    return FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: id)?.currentValue() ?? nil
}

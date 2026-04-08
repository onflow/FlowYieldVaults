import "FlowYieldVaultsAutoBalancers"

/// Returns both currentValue and valueOfDeposits for the AutoBalancer in a single script call.
/// This reduces script call overhead when both values are needed.
///
/// Returns: [currentValue, valueOfDeposits] or nil if AutoBalancer doesn't exist
///
access(all)
fun main(id: UInt64): [UFix64]? {
    if let autoBalancer = FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: id) {
        let currentValue = autoBalancer.currentValue() ?? 0.0
        let valueOfDeposits = autoBalancer.valueOfDeposits()
        return [currentValue, valueOfDeposits]
    }
    return nil
}
